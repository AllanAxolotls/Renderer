run: shaders
	swift run

shaders:
	mkdir -p Resources
	xcrun -sdk macosx metal \
		-c Sources/Renderer/Shaders/Rasterizer.metal \
		-o Resources/Rasterizer.air
	xcrun -sdk macosx metallib \
		Resources/Rasterizer.air \
		-o Resources/Rasterizer.metallib
	xcrun -sdk macosx metal \
		-c Sources/Renderer/Shaders/Raytracer.metal \
		-o Resources/Raytracer.air
	xcrun -sdk macosx metallib \
		Resources/Raytracer.air \
		-o Resources/Raytracer.metallib