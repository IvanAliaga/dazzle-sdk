// Jest config for the dazzle-react-native package.
//
// Web tests run against the real dazzle.wasm built by core/web/build.sh
// when JSDOM provides DOM globals.  Pure-logic tests (encoding /
// decoding) use a hand-rolled mock module so they don't need a browser
// runtime.

/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'jsdom',
  testMatch: ['<rootDir>/__tests__/**/*.test.ts'],
  transform: {
    '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }],
  },
  moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx', 'json', 'node'],
  setupFiles: ['<rootDir>/__tests__/setup.ts'],
};
