// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

const path = require('path');
const { getDefaultConfig, mergeConfig } =
    require('@react-native/metro-config');

// The dazzle-react-native package is linked via `file:` (a symlink in
// node_modules/ pointing to sdk/react-native/dazzle-react-native).
// When Metro transpiles a .ts inside the plugin dir it walks node_-
// modules UPWARD from that location — and never reaches this app's
// node_modules. `extraNodeModules` with a Proxy fallback fixes both
// the "unresolved @babel/runtime from plugin sources" case and the
// "react / react-native duplicate singleton" case in one block.
const pluginRoot = path.resolve(
    __dirname, '..', '..', 'sdk', 'react-native', 'dazzle-react-native');

const appNodeModules = path.resolve(__dirname, 'node_modules');

const config = {
  watchFolders: [pluginRoot],
  resolver: {
    // Metro falls back to this whenever a module isn't found via the
    // regular upward `node_modules` walk from the source file.
    // Returning the app's node_modules/<name> triggers the default
    // package.json resolution — it reads `main`, `exports`, etc.
    extraNodeModules: new Proxy(
      {
        react:          path.join(appNodeModules, 'react'),
        'react-native': path.join(appNodeModules, 'react-native'),
        'react-native-safe-area-context':
            path.join(appNodeModules, 'react-native-safe-area-context'),
      },
      {
        get: (target, name) => {
          if (name in target) return target[name];
          return path.join(appNodeModules, name);
        },
      },
    ),
    unstable_enableSymlinks: true,
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
