run: shaders
	swift run

shaders:
	mkdir -p Resources
	xcrun -sdk macosx metal \
		-c Sources/Renderer/Render/Shaders/Rasterizer.metal \
		-o Resources/Rasterizer.air
	xcrun -sdk macosx metallib \
		Resources/Rasterizer.air \
		-o Resources/Rasterizer.metallib
	xcrun -sdk macosx metal \
		-c Sources/Renderer/Render/Shaders/RayTracer.metal \
		-o Resources/RayTracer.air
	xcrun -sdk macosx metallib \
		Resources/RayTracer.air \
		-o Resources/RayTracer.metallib
	xcrun -sdk macosx metal \
		-c Sources/Renderer/Render/Shaders/Upscale.metal \
		-o Resources/Upscale.air
	xcrun -sdk macosx metallib \
		Resources/Upscale.air \
		-o Resources/Upscale.metallib