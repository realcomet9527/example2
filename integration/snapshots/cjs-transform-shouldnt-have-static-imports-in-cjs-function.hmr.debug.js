import {
__HMRModule as HMR
} from "http://localhost:8080/bun:runtime";
import {
__HMRClient as Bun
} from "http://localhost:8080/bun:runtime";
import _login from "http://localhost:8080/_login.js";
import _auth from "http://localhost:8080/_auth.js";
import * as _loginReally from "http://localhost:8080/_login.js";
import * as _loginReally2 from "http://localhost:8080/_login.js";
import * as _authReally from "http://localhost:8080/_auth.js";
Bun.activate(true);

var hmr = new HMR(3878252498, "cjs-transform-shouldnt-have-static-imports-in-cjs-function.js"), exports = hmr.exports;
(hmr._load = function() {
  function test() {
    return testDone(import.meta.url);
  }
  var foo, bar;
  hmr.exportAll({
    login: () => _login,
    test: () => test,
    foo: () => foo,
    bar: () => bar
  });
})();
var $$hmr_login = hmr.exports.login, $$hmr_test = hmr.exports.test, $$hmr_foo = hmr.exports.foo, $$hmr_bar = hmr.exports.bar;
hmr._update = function(exports) {
  $$hmr_login = exports.login;
  $$hmr_test = exports.test;
  $$hmr_foo = exports.foo;
  $$hmr_bar = exports.bar;
};

export {
  $$hmr_login as login,
  $$hmr_test as test,
  $$hmr_foo as foo,
  $$hmr_bar as bar
};
