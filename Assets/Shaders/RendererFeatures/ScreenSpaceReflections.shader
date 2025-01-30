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

			float RetrieveDepth(float2 uv)
            {
                #if UNITY_REVERSED_Z
				    return SampleSceneDepth(uv);
				#else
				    return lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(uv);
				#endif
            }

			float4 Frag(Varyings input) : SV_Target
			{
				float depth = RetrieveDepth(input.texcoord);

				float3 PixelWorldSpacePosition = ComputeWorldSpacePosition(input.texcoord, depth, UNITY_MATRIX_I_VP);
                float3 CameraWorldSpacePosition = GetCameraPositionWS();

				float3 viewDir = normalize(PixelWorldSpacePosition - CameraWorldSpacePosition);
                float3 normal = SAMPLE_TEXTURE2D(_GBuffer2Texture, sampler_GBuffer2Texture, input.texcoord).rgb;
                float3 reflectionDirection = normalize(reflect(viewDir, normal));

				float3 startPos = PixelWorldSpacePosition;
                float3 pos = startPos;

				// rough search
                for (int i = 0; i < 48; i++)
                {
                    pos = startPos + reflectionDirection * i * 1.0;
                    float2 screenUV = ComputeNormalizedDeviceCoordinates(pos, UNITY_MATRIX_VP);
                    float3 screenWithZ = ComputeNormalizedDeviceCoordinatesWithZ(pos, UNITY_MATRIX_VP);

                    if (screenUV.x > 1 || screenUV.x < 0 || screenUV.y > 1 || screenUV.y < 0)
					{
                        break;
					}

                    float testDepth = LinearEyeDepth(RetrieveDepth(screenUV), _ZBufferParams);

                    if (testDepth <= screenWithZ.z)
					{
                        break;
					}
                }

                float3 minPos = pos - reflectionDirection * 1.0;
                float3 maxPos = pos;

                // binary search
                for (int i = 0; i < 16; i++)
                {
                    pos = (minPos + maxPos) * 0.5;
                    float2 screenUV = ComputeNormalizedDeviceCoordinates(pos, UNITY_MATRIX_VP);
                    float3 screenWithZ = ComputeNormalizedDeviceCoordinatesWithZ(pos, UNITY_MATRIX_VP);

                    if (screenUV.x > 1 || screenUV.x < 0 || screenUV.y > 1 || screenUV.y < 0)
                        continue;
                        
                    float testDepth = LinearEyeDepth(RetrieveDepth(screenUV), _ZBufferParams);

                    if (testDepth <= screenWithZ.z)
                    {
                        maxPos = pos;
                    }
                    else
                    {
                        minPos = pos;
                    }
                }

				float2 screenUV = ComputeNormalizedDeviceCoordinates(pos, UNITY_MATRIX_VP);

                if (screenUV.x > 1 || screenUV.x < 0 || screenUV.y > 1 || screenUV.y < 0)
				{
                    return float4(0.0, 0.0, 0.0, 0.0);
				}

                return SAMPLE_TEXTURE2D(_BlitTexture, sampler_BlitTexture, screenUV);
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
