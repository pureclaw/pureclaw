/// <reference types="vitest/config" />
import { defineConfig, mergeConfig } from 'vite'
import viteConfig from './vite.config'

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: 'jsdom',
      globals: true,
      passWithNoTests: true,
      setupFiles: ['./src/test-setup.ts'],
      include: ['src/**/*.{test,spec}.{ts,tsx}'],
    },
  }),
)
