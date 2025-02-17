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
				float4 gBuffer2Data = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_GBuffer2Texture, input.texcoord);

				float reflectiveness = gBuffer2Data.a;
				if (reflectiveness <= 0.0) return float4(0.0, 0.0, 0.0, 0.0);

				#if UNITY_REVERSED_Z
					float rawDepth = SampleSceneDepth(input.texcoord);
				#else
					float rawDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(input.texcoord));
				#endif

				float4 posCS = ComputeClipSpacePosition(input.texcoord, rawDepth); 
				float4 posCStoVS = mul(UNITY_MATRIX_I_P, posCS);
				float3 posVS = posCStoVS.xyz / posCStoVS.w;

				float3 N_world = normalize(gBuffer2Data.rgb);
				float3 N_view = normalize(mul((float3x3)UNITY_MATRIX_V, N_world));

				float3 V_view = normalize(posVS);
				float3 R_view = normalize(reflect(V_view, N_view));

				float3 sPosVS =	posVS;
				float3 ePosVS = sPosVS + R_view * 100;

				float4 sPosCS = mul(UNITY_MATRIX_P, float4(sPosVS, 1.0));
				float4 ePosCS = ClipToFrustum(sPosCS, mul(UNITY_MATRIX_P, float4(ePosVS, 1.0)));

				float2 P0 = ((sPosCS.xy / sPosCS.w * float2(1, -1)) + 1) * 0.5;
				float2 P1 = ((ePosCS.xy / ePosCS.w * float2(1, -1)) + 1) * 0.5;

				float2 pixelP0 = float2(P0.x * _ScreenParams.x, P0.y * _ScreenParams.y);
				float2 pixelP1 = float2(P1.x * _ScreenParams.x, P1.y * _ScreenParams.y);

				float2 deltaPixel = pixelP1 - pixelP0;
				float lengthPixel = length(deltaPixel);

				float tStep = 1.0 / max(lengthPixel, 1e-6);

				// avoid self intersecting by moving a few pixels from the start.
				float pixelOffset = 1.0;
				float tOffset = pixelOffset * tStep;

				float steps = 0.0;
				// Define the maximum number of steps
				#define MAX_STEPS 150

				float startDepth = LinearEyeDepth(sPosCS.z / sPosCS.w, _ZBufferParams); // precompute z
				float endDepth = LinearEyeDepth(ePosCS.z / ePosCS.w, _ZBufferParams); // precompute z

				[loop]
				for (float t = tOffset; t < 1.0 && steps < MAX_STEPS; t += tStep, steps += 1)
				{
					float4 pos = lerp(sPosCS, ePosCS, t);
					float testDepth = LinearEyeDepth(pos.z / pos.w, _ZBufferParams);

					//testDepth = lerp(startDepth, endDepth, t);

					float2 uv = (((pos.xy / pos.w) * float2(1, -1)) + 1) * 0.5;
					//uv = lerp(P0, P1, t); // not correct: linear depth seems not to match with this uv interpolation.

					#if UNITY_REVERSED_Z
						float sceneDepth = LinearEyeDepth(SampleSceneDepth(uv), _ZBufferParams);
					#else
						float sceneDepth = LinearEyeDepth(lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(uv)), _ZBufferParams);
					#endif

					if (sceneDepth < testDepth)
					{
						return SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, uv);
					}
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

			Texture2D _FirstPassTexture;
			SAMPLER(sampler_FirstPassTexture);

			float4 Frag(Varyings input) : SV_Target
			{
				float4 smoothness = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_GBuffer2Texture, input.texcoord).a;
                float4 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, input.texcoord);
                float4 reflectedColor = SAMPLE_TEXTURE2D(_FirstPassTexture, sampler_FirstPassTexture, input.texcoord);
				float4 finalColor = lerp(color, reflectedColor, smoothness * reflectedColor.a); // no branch
                return float4(finalColor.r, finalColor.g, finalColor.b, 1.0);
			}

			ENDHLSL
		}
	}
}