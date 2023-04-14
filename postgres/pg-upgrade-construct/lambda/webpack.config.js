const webpack = require("webpack")

const files = {
    "invoker": "./invoker.js", 
    "is-complete": "./is-complete.js", 
}

module.exports = {
    entry: files,
    externals: ["bufferutil", "utf-8-validate"],
    output: {
        path: __dirname + "/dist",
        filename: "[name].js",
        libraryTarget: "commonjs2",
    },
    plugins: [
        new webpack.IgnorePlugin({ resourceRegExp: /^pg-native$/ }),
    ],
    target: "node",
    module: {
        rules: [],
    },
    mode: "production",
}
