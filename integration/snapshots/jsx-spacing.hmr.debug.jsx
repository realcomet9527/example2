import {
__HMRClient as Bun
} from "http://localhost:8080/bun:runtime";
import {
__require as require
} from "http://localhost:8080/bun:runtime";
import {
__HMRModule as HMR
} from "http://localhost:8080/bun:runtime";
import * as JSX from "http://localhost:8080/node_modules/react/jsx-dev-runtime.js";
var jsx = require(JSX).jsxDEV;

import * as $1f6f0e67 from "http://localhost:8080/node_modules/react-dom/server.browser.js";
var ReactDOM = require($1f6f0e67);
Bun.activate(true);

var hmr = new HMR(3614189736, "jsx-spacing.jsx"), exports = hmr.exports;
(hmr._load = function() {
  const ReturnDescriptionAsString = ({ description }) => description;
  function test() {
    const _bun = ReactDOM.renderToString(jsx(ReturnDescriptionAsString, {
      description: `line1
line2 trailing space 

line4 no trailing space 'single quote' \\t\\f\\v\\uF000 \`template string\`

line6 no trailing space
line7 trailing newline that \${terminates} the string literal
`
    }, undefined, false, undefined, this));
    const el = document.createElement("textarea");
    el.innerHTML = _bun;
    const bun = el.value;
    const esbuild = `line1
line2 trailing space 

line4 no trailing space 'single quote' \\t\\f\\v\\uF000 \`template string\`

line6 no trailing space
line7 trailing newline that \${terminates} the string literal
`;
    const tsc = `line1
line2 trailing space 

line4 no trailing space 'single quote' \\t\\f\\v\\uF000 \`template string\`

line6 no trailing space
line7 trailing newline that \${terminates} the string literal
`;
    console.assert(bun === esbuild && bun === tsc, `strings did not match: ${JSON.stringify({
      received: bun,
      expected: esbuild
    }, null, 2)}`);
    testDone(import.meta.url);
  }
  hmr.exportAll({
    test: () => test
  });
})();
var $$hmr_test = hmr.exports.test;
hmr._update = function(exports) {
  $$hmr_test = exports.test;
};

export {
  $$hmr_test as test
};
