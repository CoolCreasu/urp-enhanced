// Based on https://sugulee.wordpress.com/2021/01/16/performance-optimizations-for-screen-space-reflections-technique-part-1-linear-tracing-method/
// TODO implement Hi-z

Shader "RendererFeatures/LinearSSR"
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

			Texture2D _GBuffer2Texture;

			void ComputePosAndReflection(float2 uv, float3 normalInVS, out float3 outSamplePosInTS,  out float3 outDirectionInTS, out float outMaxDistance)
			{
				#if UNITY_REVERSED_Z
					float sampleDepth = SampleSceneDepth(uv);
				#else
					float sampleDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(uv));
				#endif

				float4 samplePosInCS = float4(uv.x * 2 - 1, uv.y * 2 - 1, sampleDepth, 1.0);

				#if UNITY_UV_STARTS_AT_TOP
					samplePosInCS = float4(samplePosInCS.x, -samplePosInCS.y, samplePosInCS.z, samplePosInCS.w);
				#endif

				float4 samplePosInVS = mul(UNITY_MATRIX_I_P, samplePosInCS);
				samplePosInVS /= samplePosInVS.w;

				float3 viewDirInVS = normalize(samplePosInVS.xyz);
				float4 reflectionInVS = float4(reflect(viewDirInVS.xyz, normalInVS.xyz), 0.0);

				float3 endPosInVS = samplePosInVS + reflectionInVS * 1000.0;
				float4 endPosInCS = mul(UNITY_MATRIX_P, float4(endPosInVS.xyz, 1.0));
				endPosInCS /= endPosInCS.w;
				float3 directionInTS = normalize((endPosInCS - samplePosInCS).xyz);

				#if UNITY_UV_STARTS_AT_TOP
					samplePosInCS = float4(samplePosInCS.x * 0.5, samplePosInCS.y * -0.5, samplePosInCS.z, samplePosInCS.w);
					samplePosInCS = float4(samplePosInCS.x + 0.5, samplePosInCS.y + 0.5, samplePosInCS.z, samplePosInCS.w);

					directionInTS = float3(directionInTS.x * 0.5, directionInTS.y * -0.5, directionInTS.z);
				#else
					samplePosInCS = float4(samplePosInCS.x * 0.5, samplePosInCS.y * 0.5, samplePosInCS.z, samplePosInCS.w);
					samplePosInCS = float4(samplePosInCS.x + 0.5, samplePosInCS.y + 0.5, samplePosInCS.z, samplePosInCS.w);

					directionInTS = float3(directionInTS.x * 0.5, directionInTS.y * 0.5, directionInTS.z);
				#endif
				
				outSamplePosInTS = samplePosInCS.xyz;
				outDirectionInTS = directionInTS;

				outMaxDistance = outDirectionInTS.x >= 0 ? (1 - outSamplePosInTS.x) / outDirectionInTS.x : -outSamplePosInTS.x / outDirectionInTS.x;
				outMaxDistance = min(outMaxDistance, outDirectionInTS.y < 0 ? (-outSamplePosInTS.y) / outDirectionInTS.y : ((1-outSamplePosInTS.y) / outDirectionInTS.y));
				outMaxDistance = min(outMaxDistance, outDirectionInTS.z < 0 ? (-outSamplePosInTS.z) / outDirectionInTS.z : ((1-outSamplePosInTS.z) / outDirectionInTS.z));
			}

			bool FindIntersectionLinear(float3 samplePosInTS, float3 reflDirInTS, float maxTraceDistance, out float3 intersection)
			{
				intersection = 0.0;
				float3 reflectionEndPosInTS = samplePosInTS + reflDirInTS * maxTraceDistance;

				float3 delta = reflectionEndPosInTS.xyz - samplePosInTS.xyz;
				int2 sampleScreenPos = int2(samplePosInTS.xy * _ScreenParams.xy);
				int2 endPosScreenPos = int2(reflectionEndPosInTS.xy * _ScreenParams.xy);
				int2 pixelDelta = endPosScreenPos - sampleScreenPos;
				const float maxDistance = max(abs(pixelDelta.x), abs(pixelDelta.y));
				delta /= maxDistance;

				float4 rayPosInTS = float4(samplePosInTS + delta, 0.0);
				float4 rayDirInTS = float4(delta.xyz, 0.0);
				float4 rayStartPos = rayPosInTS;

				const float maxIterations = 256;

				float hitIndex = -1;
				[loop]
				for (float i = 0; i <= maxDistance && i < maxIterations; i++)
				{
					#if UNITY_REVERSED_Z
						float rawSceneDepth = SampleSceneDepth(rayPosInTS.xy);
					#else
						float rawSceneDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(rayPosInTS.xy));
					#endif
					float linearSceneDepth = LinearEyeDepth(rawSceneDepth, _ZBufferParams);

					float rawTestDepth = rayPosInTS.z;
					float linearTestDepth = LinearEyeDepth(rawTestDepth, _ZBufferParams);
					
					float thickness = linearTestDepth - linearSceneDepth;
					hitIndex = (thickness >= 0 && thickness < 1) ? (i) : hitIndex;

					if (hitIndex != -1) break;

					rayPosInTS = rayPosInTS + rayDirInTS;
				}

				bool intersected = hitIndex >= 0;
				intersection = rayStartPos.xyz + rayDirInTS.xyz * hitIndex;

				float intensity = intersected ? 1 : 0;
				return intensity;
			}

			float4 ComputeReflectedColor(float intensity, float3 intersection)
			{
				return SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, intersection.xy);
			}

			float4 Frag(Varyings input) : SV_Target
			{
				float4 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, input.texcoord);
				float4 normalInWS = float4(normalize(SampleSceneNormals(input.texcoord).xyz), 0.0);
				float3 normal = mul(UNITY_MATRIX_V, normalInWS).xyz;
				float smoothness = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_PointClamp, input.texcoord).a;

				float4 reflectionColor = 0.0;
				if (smoothness != 0)
				{
					float3 samplePosInTS = 0.0;
					float3 directionInTS = 0.0;
					float maxDistance = 0.0;

					ComputePosAndReflection(input.texcoord.xy, normal, samplePosInTS, directionInTS, maxDistance);

					float3 intersection = 0;
					float intensity = FindIntersectionLinear(samplePosInTS, directionInTS, maxDistance, intersection);

					reflectionColor = ComputeReflectedColor(intensity, intersection);
				}

				return (color * 0.1) + (reflectionColor* 0.9);
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

			Texture2D _GBuffer2Texture;
			Texture2D _LinearSSR_FirstPassTexture;

			float4 Frag(Varyings input) : SV_Target
			{
				float smoothness = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_PointClamp, input.texcoord).a;
				float3 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, input.texcoord).rgb;
				float4 reflectionColor = SAMPLE_TEXTURE2D(_LinearSSR_FirstPassTexture, sampler_PointClamp, input.texcoord).rgba;
				color = lerp(color.rgb, reflectionColor.rgb, smoothness * reflectionColor.a); // smoothness * 1 or smoothness * 0
				return float4(color.rgb, 1.0);
			}

			ENDHLSL
		}
	}
}