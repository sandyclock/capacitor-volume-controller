/*
 * ⚠️ Two PRE-EXISTING defects fixed here (inherited from upstream, not introduced by the
 * fork). Before this, `npx jest` could not start at all:
 *
 *  1. testEnvironment was 'jsdom', but `jest-environment-jsdom` is not installed -- Jest 28+
 *     stopped shipping it by default, so every run died with "Test environment
 *     jest-environment-jsdom cannot be found". These tests exercise a plain class and touch
 *     no DOM, so 'node' is both correct and cheaper than pulling jsdom back in.
 *  2. `moduleNameMapping` is not a Jest option -- the real name is `moduleNameMapper`. Jest
 *     reported it as an unknown option and the `@/` alias silently never worked.
 */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx'],
  transform: {
    '^.+\\.(ts|tsx)$': 'ts-jest',
  },
  testMatch: ['**/__tests__/**/*.(ts|tsx|js)', '**/*.(test|spec).(ts|tsx|js)'],
  // Without this, jest re-discovers the COMPILED copies under dist/ and runs each suite
  // twice -- the dist copies failing because they are emitted JS/d.ts, not sources.
  testPathIgnorePatterns: ['/node_modules/', '/dist/'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1',
  },
  collectCoverageFrom: [
    'src/**/*.{ts,tsx}',
    '!src/**/*.d.ts',
    '!src/index.ts',
  ],
  coverageDirectory: 'coverage',
  coverageReporters: ['html', 'text', 'lcov'],
};