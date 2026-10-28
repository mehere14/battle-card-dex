import { defineConfig } from 'vite';
import { cpSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export default defineConfig({
  plugins: [{
    name: 'mockup-artwork',
    closeBundle() {
      cpSync(fileURLToPath(new URL('./Mockup Assets/', import.meta.url)),
        fileURLToPath(new URL('./dist/Mockup Assets/', import.meta.url)), { recursive: true });
    }
  }]
});
