Shader "RendererFeatures/SSR"
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
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"

			#pragma vertex Vert
			#pragma fragment Frag

			#pragma multi_compile _ _GBUFFER_NORMALS_OCT

			SAMPLER(sampler_BlitTexture);

			Texture2D _GBuffer2Texture;
			SAMPLER(sampler_GBuffer2Texture);

			float4 ClipToFrustum(float4 sPosCS, float4 ePosCS)
			{
				float tClip = 1.0;
				float4 delta = ePosCS - sPosCS;

				// X axis

				// Right plane : X = w
				if (ePosCS.x >= ePosCS.w && abs(delta.x - delta.w) > 1e-6)
				{
					float tCandidate = (sPosCS.w - sPosCS.x) / (delta.x - delta.w);
					tClip = min(tClip, tCandidate);
				}

				// Left plane : X = -w
				if (ePosCS.x <= -ePosCS.w && abs(delta.x + delta.w) > 1e-6)
				{
					float tCandidate = (-sPosCS.w - sPosCS.x) / (delta.x + delta.w);
					tClip = min(tClip, tCandidate);
				}

				// Y axis

				// Top plane : Y = w
				if (ePosCS.y >= ePosCS.w && abs(delta.y - delta.w) > 1e-6)
				{
					float tCandidate = (sPosCS.w - sPosCS.y) / (delta.y - delta.w);
					tClip = min(tClip, tCandidate);
				}

				// Bottom plane : Y = -w
				if (ePosCS.y <= -ePosCS.w && abs(delta.y + delta.w) > 1e-6)
				{
					float tCandidate = (-sPosCS.w - sPosCS.y) / (delta.y + delta.w);
					tClip = min(tClip, tCandidate);
				}

				// Z axis

				// Far plane : z = w
				if (ePosCS.z >= ePosCS.w && abs(delta.z - delta.w) > 1e-6)
				{
					float tCandidate = (sPosCS.w - sPosCS.z) / (delta.z - delta.w);
					tClip = min(tClip, tCandidate);
				}

				// Near plane : Z = 0
				if (ePosCS.z <= 0 && abs(delta.z) > 1e-6)
				{
					float tCandidate = -sPosCS.z / delta.z;
					tClip = min(tClip, tCandidate);
				}

				tClip = saturate(tClip);
				return sPosCS + tClip * delta;
			}

			float4 Frag(Varyings input) : SV_Target
			{
				float smoothness = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_GBuffer2Texture, input.texcoord).a;
				if (smoothness <= 0.0) return float4(0.0, 0.0, 0.0, 0.0);

				float3 N_world = normalize(SampleSceneNormals(input.texcoord).xyz);
				float3 N_view = normalize(mul((float3x3)UNITY_MATRIX_V, N_world.xyz));

				#if UNITY_REVERSED_Z
					float rawDepth = SampleSceneDepth(input.texcoord);
				#else
					float rawDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(input.texcoord));
				#endif

				float4 posCS = ComputeClipSpacePosition(input.texcoord.xy, rawDepth);
				float4 posVS = mul(UNITY_MATRIX_I_P, posCS);
				posVS /= posVS.w;

				float3 V_view = normalize(posVS);
				float3 R_view = normalize(reflect(V_view, N_view));

				float3 sPosVS = posVS;
				float3 ePosVS = posVS + R_view * 1000.0;
				
				float4 sPosCS = mul(UNITY_MATRIX_P, float4(sPosVS, 1.0));
				float4 ePosCS = mul(UNITY_MATRIX_P, float4(ePosVS, 1.0));
				ePosCS = ClipToFrustum(sPosCS, ePosCS);

				float3 sPosNDC = sPosCS.xyz / sPosCS.w;
				float3 ePosNDC = ePosCS.xyz / ePosCS.w;

				float3 sPosTS = float3(sPosNDC.x * 0.5 + 0.5, sPosNDC.y * 0.5 + 0.5, sPosNDC.z);
				float3 ePosTS = float3(ePosNDC.x * 0.5 + 0.5, ePosNDC.y * 0.5 + 0.5, ePosNDC.z);

				#if UNITY_UV_STARTS_AT_TOP
					sPosTS.xyz = float3(sPosTS.x, 1 - sPosTS.y, sPosTS.z);
					ePosTS.xyz = float3(ePosTS.x, 1 - ePosTS.y, ePosTS.z);
				#endif

				float3 delta = (ePosTS.xyz - sPosTS.xyz);
				float2 pixelDelta = (ePosTS.xy * _ScreenParams.xy) - (sPosTS.xy * _ScreenParams.xy);
				float maxSteps = max(abs(pixelDelta.x), abs(pixelDelta.y));
				delta = delta / maxSteps;

				float4 positionTS = float4(sPosTS.xyz + delta.xyz, 0.0);
				float4 directionTS = float4(delta.xyz, 0);

				bool hit = false;

				[loop]
				for (int i = 0; i < 256; i++)
				{
					if (positionTS.x < 0 || positionTS.x > 1 || positionTS.y < 0 || positionTS.y > 1)
					{
						break;
					}

					#if UNITY_REVERSED_Z
						float rawSceneDepth = SampleSceneDepth(positionTS.xy);
					#else
						float rawSceneDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(positionTS.xy));
					#endif
					float linearSceneDepth = LinearEyeDepth(rawSceneDepth, _ZBufferParams);

					float rawTestDepth = positionTS.z;
					float linearTestDepth = LinearEyeDepth(rawTestDepth, _ZBufferParams);
					
					float thickness = abs(linearTestDepth - linearSceneDepth);
					float t = linearSceneDepth / _ProjectionParams.z;
					//float thicknessThreshold = lerp(0.2, 2500.0, t);
					float thicknessThreshold = _ZBufferParams.z * 0.5;

					if (linearTestDepth >= linearSceneDepth && thickness < thicknessThreshold)
					{
						//if (linearTestDepth >= _ZBufferParams.z * 0.99 || linearSceneDepth >= _ZBufferParams.z * 0.99)
						//{
						//	hit = false;
						//	break;
						//}
						//else
						//{
							hit = true;
							break;
						//}
					}

					positionTS = positionTS + directionTS;
				}

				if (hit)
				{
					return SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, positionTS.xy);
				}

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

			Texture2D _SSR_FirstPassTexture;
			SAMPLER(sampler_SSR_FirstPassTexture);

			float4 Frag(Varyings input) : SV_Target
			{
				float smoothness = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_GBuffer2Texture, input.texcoord).a;
				float3 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, input.texcoord).rgb;
				float4 reflectionColor = SAMPLE_TEXTURE2D(_SSR_FirstPassTexture, sampler_SSR_FirstPassTexture, input.texcoord).rgba;
				color = lerp(color.rgb, reflectionColor.rgb, smoothness * reflectionColor.a); // smoothness * 1 or smoothness * 0
				return float4(color.rgb, 1.0);
			}

			ENDHLSL
		}
	}
}