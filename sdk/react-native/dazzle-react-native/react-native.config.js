// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Autolinking metadata. Tells RN where our native module lives so
// consumer apps pick it up automatically via `npm install`.

module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: './android',
        packageImportPath: 'import dev.dazzle.rn.DazzleReactNativePackage;',
        packageInstance: 'new DazzleReactNativePackage()',
      },
      ios: {
        podspecPath: __dirname + '/dazzle-react-native.podspec',
      },
    },
  },
};
