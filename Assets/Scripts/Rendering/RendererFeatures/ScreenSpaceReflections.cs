using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.Universal;

namespace Enhanced.Rendering.RendererFeatures
{
    public class ScreenSpaceReflections : ScriptableRendererFeature
    {
        [SerializeField] private Material material = default;
        private ScreenSpaceReflectionsRenderPass renderpass = default;

        public override void Create()
        {
            renderpass = new ScreenSpaceReflectionsRenderPass(material);
            renderpass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (renderpass == null) return;
            renderer.EnqueuePass(renderpass);
        }

        private class ScreenSpaceReflectionsRenderPass : ScriptableRenderPass
        {
            private Material material = default;

            private RenderTextureDescriptor commonRenderTextureDescriptor = default;
            private TextureHandle firstPassTextureHandle = default;
            private TextureHandle secondPassTextureHandle = default;
            private TextureHandle gBuffer2TextureHandle = default;

            public ScreenSpaceReflectionsRenderPass(Material material)
            {
                this.material = material;

                commonRenderTextureDescriptor = new RenderTextureDescriptor(Screen.width, Screen.height, RenderTextureFormat.ARGBFloat, 0);
            }

            public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
            {
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
                UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();

                if (resourceData.isActiveTargetBackBuffer) return;

                commonRenderTextureDescriptor.width = cameraData.cameraTargetDescriptor.width;
                commonRenderTextureDescriptor.height = cameraData.cameraTargetDescriptor.height;
                commonRenderTextureDescriptor.depthBufferBits = 0;

                firstPassTextureHandle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, commonRenderTextureDescriptor, "_FirstPassTexture", false);
                secondPassTextureHandle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, commonRenderTextureDescriptor, "_SecondPassTexture", false);
                gBuffer2TextureHandle = resourceData.gBuffer[2];

                if (!firstPassTextureHandle.IsValid() || !secondPassTextureHandle.IsValid() || !gBuffer2TextureHandle.IsValid()) return;

                // first pass, raymarching
                using (var builder = renderGraph.AddRasterRenderPass<PassData>("RaymarchPass", out var passData))
                {
                    passData.source = resourceData.cameraColor;
                    passData.target = firstPassTextureHandle;
                    passData.material = material;

                    builder.UseTexture(passData.source, AccessFlags.Read);
                    builder.UseTexture(gBuffer2TextureHandle, AccessFlags.Read);
                    builder.SetRenderAttachment(passData.target, 0, AccessFlags.Write);
                    builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
                    {
                        material.SetTexture("_GBuffer2Texture", gBuffer2TextureHandle);
                        Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, 0);
                    });
                }

                // second pass, composition
                using (var builder = renderGraph.AddRasterRenderPass<PassData>("CompositePass", out var passData))
                {
                    passData.source = resourceData.cameraColor;
                    passData.target = secondPassTextureHandle;
                    passData.material = material;

                    builder.UseTexture(passData.source, AccessFlags.Read);
                    builder.UseTexture(gBuffer2TextureHandle, AccessFlags.Read);
                    builder.UseTexture(firstPassTextureHandle, AccessFlags.Read);
                    builder.SetRenderAttachment(passData.target, 0, AccessFlags.Write);
                    builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
                    {
                        material.SetTexture("_GBuffer2Texture", gBuffer2TextureHandle);
                        material.SetTexture("_FirstPassTexture", firstPassTextureHandle);
                        Blitter.BlitTexture(context.cmd, data.source, new Vector4(1, 1, 0, 0), data.material, 1);
                    });
                }

                // finally copy result to camera
                resourceData.cameraColor = secondPassTextureHandle;
            }

            private class PassData
            {
                public TextureHandle source = default;
                public TextureHandle target = default;
                public Material material = default;
            }
        }
    }
}