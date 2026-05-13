/* ═══════════════════════════════════════════════
   CoEvo Landing — Three.js Hero Particles
   ═══════════════════════════════════════════════ */

(function() {
  'use strict';

  const canvas = document.getElementById('particleCanvas');
  if (!canvas) return;

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);
  const renderer = new THREE.WebGLRenderer({
    canvas,
    alpha: true,
    antialias: true,
  });
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));

  // ─── Particles ───
  const particleCount = Math.min(Math.floor(window.innerWidth * 0.15), 200);
  const geometry = new THREE.BufferGeometry();
  const positions = new Float32Array(particleCount * 3);
  const colors = new Float32Array(particleCount * 3);
  const sizes = new Float32Array(particleCount);

  const colorPalette = [
    new THREE.Color(0x6C63FF), // accent
    new THREE.Color(0x8B85FF), // accent light
    new THREE.Color(0xE040FB), // pink
    new THREE.Color(0x7C4DFF), // purple
  ];

  for (let i = 0; i < particleCount; i++) {
    positions[i * 3] = (Math.random() - 0.5) * 20;
    positions[i * 3 + 1] = (Math.random() - 0.5) * 20;
    positions[i * 3 + 2] = (Math.random() - 0.5) * 20;

    const color = colorPalette[Math.floor(Math.random() * colorPalette.length)];
    colors[i * 3] = color.r;
    colors[i * 3 + 1] = color.g;
    colors[i * 3 + 2] = color.b;

    sizes[i] = Math.random() * 3 + 1;
  }

  geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  geometry.setAttribute('size', new THREE.BufferAttribute(sizes, 1));

  // ─── Particle Texture (soft circle) ───
  const textureCanvas = document.createElement('canvas');
  textureCanvas.width = 32;
  textureCanvas.height = 32;
  const ctx = textureCanvas.getContext('2d');
  const gradient = ctx.createRadialGradient(16, 16, 0, 16, 16, 16);
  gradient.addColorStop(0, 'rgba(255,255,255,1)');
  gradient.addColorStop(0.3, 'rgba(255,255,255,0.8)');
  gradient.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, 32, 32);
  const particleTexture = new THREE.CanvasTexture(textureCanvas);

  const material = new THREE.PointsMaterial({
    size: 0.12,
    map: particleTexture,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
    transparent: true,
    vertexColors: true,
    opacity: 0.8,
  });

  const particles = new THREE.Points(geometry, material);
  scene.add(particles);

  // ─── Connection Lines ───
  const lineGeometry = new THREE.BufferGeometry();
  const linePositions = [];
  const connectionDistance = 3.5;

  for (let i = 0; i < particleCount; i++) {
    for (let j = i + 1; j < particleCount; j++) {
      const dx = positions[i * 3] - positions[j * 3];
      const dy = positions[i * 3 + 1] - positions[j * 3 + 1];
      const dz = positions[i * 3 + 2] - positions[j * 3 + 2];
      const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dist < connectionDistance && Math.random() < 0.15) {
        linePositions.push(
          positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2],
          positions[j * 3], positions[j * 3 + 1], positions[j * 3 + 2]
        );
      }
    }
  }

  lineGeometry.setAttribute('position', new THREE.Float32BufferAttribute(linePositions, 3));

  const lineMaterial = new THREE.LineBasicMaterial({
    color: 0x6C63FF,
    transparent: true,
    opacity: 0.08,
  });

  const lines = new THREE.LineSegments(lineGeometry, lineMaterial);
  scene.add(lines);

  camera.position.z = 8;

  // ─── Mouse interaction ───
  let mouseX = 0;
  let mouseY = 0;
  let targetRotX = 0;
  let targetRotY = 0;

  document.addEventListener('mousemove', (e) => {
    mouseX = (e.clientX / window.innerWidth) * 2 - 1;
    mouseY = -(e.clientY / window.innerHeight) * 2 + 1;
    targetRotX = mouseY * 0.1;
    targetRotY = mouseX * 0.1;
  });

  // ─── Resize ───
  window.addEventListener('resize', () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
  });

  // ─── Animation Loop ───
  let currentRotX = 0;
  let currentRotY = 0;

  function animate() {
    requestAnimationFrame(animate);

    // Smooth rotation following mouse
    currentRotX += (targetRotX - currentRotX) * 0.02;
    currentRotY += (targetRotY - currentRotY) * 0.02;

    particles.rotation.x = currentRotX;
    particles.rotation.y = currentRotY + Date.now() * 0.00005;
    lines.rotation.x = currentRotX;
    lines.rotation.y = currentRotY + Date.now() * 0.00005;

    renderer.render(scene, camera);
  }

  animate();
})();
