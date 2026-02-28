import sharp from 'sharp';

type Size = {
  width: number;
  height: number;
};

async function resizeImage(buffer: Buffer, size: Size) {
  return sharp(buffer, { failOn: 'none' })
    .resize({
      width: size.width,
      height: size.height,
      fit: 'inside',
      withoutEnlargement: true
    });
}

export async function buildPngSquareVariant(buffer: Buffer, pixels: number) {
  const pipeline = await resizeImage(buffer, { width: pixels, height: pixels });
  return pipeline.png().toBuffer();
}

export async function buildWebpSquareVariant(buffer: Buffer, pixels: number) {
  const pipeline = await resizeImage(buffer, { width: pixels, height: pixels });
  return pipeline.webp().toBuffer();
}
