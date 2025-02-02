Shader "RendererFeatures/ScreenSpaceReflections"
{
	SubShader
	{
		Tags
		{
			"RenderPipeline" = "UniversalPipeline"
		}

		Pass
		{
			Name "RaymarchPass"

			ZTest Always
			ZWrite Off
			Cull Off
			Blend Off

			HLSLPROGRAM

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

			#pragma vertex Vert
			#pragma fragment Frag

			SAMPLER(sampler_BlitTexture);

			Texture2D _GBuffer2Texture;
			SAMPLER(sampler_GBuffer2Texture);

			float4 Frag(Varyings input) : SV_Target
			{
				float4 gBuffer2Info = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_GBuffer2Texture, input.texcoord);

				float reflectiveness = gBuffer2Info.a;
				if (reflectiveness <= 0.0) return float4(0.0, 0.0, 0.0, 0.0);

				#if UNITY_REVERSED_Z
					float depth = SampleSceneDepth(input.texcoord);
				#else
					float depth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(input.texcoord));
				#endif

				// not using ComputeViewSpacePosition(input.texcoord, depth, UNITY_MATRIX_I_P) because it flips the z.
				float4 posCS = ComputeClipSpacePosition(input.texcoord, depth); 
				float4 posCStoVS = mul(UNITY_MATRIX_I_P, posCS);
				float3 posVS = posCStoVS.xyz / posCStoVS.w;

				float3 N_world = normalize(gBuffer2Info.rgb);
				float3 N_view = normalize(mul((float3x3)UNITY_MATRIX_V, N_world));

				float3 V_view = normalize(posVS);
				float3 R_view = normalize(reflect(V_view, N_view));

				float3 rayposVS = posVS + R_view * 0.001;
				float3 projUV = float3(input.texcoord, 0.0);

				float hitT = -1.0;

				const float stepSize = 0.5;

				[loop]
				for (int i = 0; i < 128; i++)
				{
					rayposVS = rayposVS + (R_view * stepSize);

					projUV = ComputeNormalizedDeviceCoordinatesWithZ(rayposVS, UNITY_MATRIX_P);

					if (projUV.x < 0 || projUV.x > 1 || projUV.y < 0 || projUV.y > 1)
					{
						return float4(0.0, 0.0, 0.0, 0.0);
					}

					#if UNITY_REVERSED_Z
						float testDepth = LinearEyeDepth(SampleSceneDepth(projUV.xy), _ZBufferParams);
					#else
						float testDepth = LinearEyeDepth(lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(projUV.xy)), _ZBufferParams);
					#endif

					[branch]
					if (testDepth <= projUV.z)
					{
						hitT = 0.001 + i * stepSize;
						break;
					}
				}

				[branch]
				if (hitT >= 0.0)
				{
					float tMin = hitT - 1.0;
					float tMax = hitT;

					[loop]
					for (int i = 0; i < 64; i++)
					{
						float tMid = (tMin + tMax) * 0.5;
						rayposVS = posVS + (R_view * tMid);

						projUV = ComputeNormalizedDeviceCoordinatesWithZ(rayposVS, UNITY_MATRIX_P);

						#if UNITY_REVERSED_Z
							float testDepth = LinearEyeDepth(SampleSceneDepth(projUV.xy), _ZBufferParams);
						#else
							float testDepth = LinearEyeDepth(lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(projUV.xy)), _ZBufferParams);
						#endif

						[branch]
						if (testDepth <= projUV.z)
						{
							tMax = tMid;
						}
						else
						{
							tMin = tMid;
						}
					}
				}

				return SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, projUV.xy);
			}

			ENDHLSL
		}

		Pass
		{
			Name "CompositePass"
			
			ZTest Always
			ZWrite Off
			Cull Off
			Blend Off

			HLSLPROGRAM

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

			#pragma vertex Vert
			#pragma fragment Frag

			SAMPLER(sampler_BlitTexture);

			Texture2D _GBuffer2Texture;
			SAMPLER(sampler_GBuffer2Texture);

			Texture2D _FirstPassTexture;
			SAMPLER(sampler_FirstPassTexture);

			float4 Frag(Varyings input) : SV_Target
			{
				float4 smoothness = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_GBuffer2Texture, input.texcoord).a;
                float4 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, input.texcoord);
                float4 reflectedColor = SAMPLE_TEXTURE2D(_FirstPassTexture, sampler_FirstPassTexture, input.texcoord);
                float4 finalColor = (reflectedColor.a == 0.0) ? color : saturate((1 - smoothness) * color + reflectedColor * smoothness);

                return float4(finalColor.r, finalColor.g, finalColor.b, 1.0);
			}

			ENDHLSL
		}
	}

	// Fallback

	SubShader
	{
		Tags
		{
			"RenderPipeline" = "UniversalPipeline"
		}

		Pass
		{
			Name "FallbackPass1"

			ZTest Always
			ZWrite Off
			Cull Off
			Blend Off

			HLSLPROGRAM

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

			#pragma vertex Vert
			#pragma fragment Frag

			SAMPLER(sampler_BlitTexture);

			float4 Frag(Varyings input) : SV_Target
			{
				float4 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, input.texcoord);
				return color;
			}

			ENDHLSL
		}

		Pass
		{
			Name "FallbackPass2"

			ZTest Always
			ZWrite Off
			Cull Off
			Blend Off

			HLSLPROGRAM

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

			#pragma vertex Vert
			#pragma fragment Frag

			SAMPLER(sampler_BlitTexture);

			float4 Frag(Varyings input) : SV_Target
			{
				float4 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, input.texcoord);
				return color;
			}

			ENDHLSL
		}
	}
}
