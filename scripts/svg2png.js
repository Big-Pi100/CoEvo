const { promises: fs } = require('fs');
const { Resvg } = require('@resvg/resvg-js');

async function main() {
  const svgPath = 'E:\\CoEvo\\docs\\cover-note-01.svg';
  const pngPath = 'E:\\CoEvo\\docs\\cover-note-01.png';

  const svg = await fs.readFile(svgPath, 'utf8');

  const opts = {
    fitTo: {
      mode: 'width',
      value: 1080,
    },
    background: '#0D1B2A',
  };

  const resvg = new Resvg(svg, opts);
  const pngBuffer = resvg.render().asPng();

  await fs.writeFile(pngPath, pngBuffer);
  console.log(`PNG saved: ${pngPath} (${(pngBuffer.length / 1024).toFixed(1)} KB)`);
}

main().catch(console.error);
