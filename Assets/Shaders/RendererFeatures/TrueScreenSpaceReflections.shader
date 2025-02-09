Shader "RendererFeatures/TrueScreenSpaceReflections"
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
				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

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

				float3 startPosVS = posVS;
				float3 endPosVS = startPosVS + R_view * 0.2 * 128; // stepsize * maxsteps

				float3 pos = float3(0.0, 0.0, 0.0);
				float3 uv = float3(0.0, 0.0, 0.0);
				float tPrev = 0;
				float t = 0;
				bool hitFound = 0;

				[loop] // unrolling is too complex so can only keep the loop
				for (int i = 0; i <= 128; i++)
				{
					tPrev = t;
					t = (float)i / 128.0;
					pos = lerp(startPosVS, endPosVS, t);
					uv = ComputeNormalizedDeviceCoordinatesWithZ(pos, UNITY_MATRIX_P);

					if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1)
					{
						return float4(0.0, 0.0, 0.0, 0.0);
					}

					#if UNITY_REVERSED_Z
						float sceneDepth = SampleSceneDepth(uv.xy);
					#else
						float sceneDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(uv.xy));
					#endif

					if (sceneDepth > uv.z + 0.001)
					{
						hitFound = 1;
						//return SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, uv.xy);
						break;
					}
				}

				if (hitFound == 0) return float4(0.0, 0.0, 0.0, 0.0);

				float3 minPos = lerp(startPosVS, endPosVS, tPrev);
				float3 maxPos = lerp(startPosVS, endPosVS, t);

				// TODO binary search
				[loop]
				for (int i = 0; i <= 8; i++)
				{
					float3 midPos = (minPos + maxPos) * 0.5;
					uv = ComputeNormalizedDeviceCoordinatesWithZ(midPos, UNITY_MATRIX_P);

					if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1)
					{
						return float4(0.0, 0.0, 0.0, 0.0);
					}

					#if UNITY_REVERSED_Z
						float sceneDepth = SampleSceneDepth(uv.xy);
					#else
						float sceneDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(uv.xy));
					#endif

					if (sceneDepth > uv.z + 0.001) // Object hit, we are in front
					{
						maxPos = midPos; // Move t closer to tMid
					}
					else // Object not hit, we're behind
					{
						minPos = midPos; // Move tPrev closer to tMid
					}
				}

				return SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, uv.xy);

				return float4(0.0, 0.0, 0.0, 0.0);
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
                //float4 finalColor = (reflectedColor.a == 0.0) ? color : saturate((1 - smoothness) * color + reflectedColor * smoothness);
				float4 finalColor = lerp(color, reflectedColor, smoothness * reflectedColor.a);

                return float4(finalColor.r, finalColor.g, finalColor.b, 1.0);
			}

			ENDHLSL
		}
	}
}