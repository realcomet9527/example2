import {
__HMRModule as HMR
} from "http://localhost:8080/bun:runtime";
import {
__HMRClient as Bun
} from "http://localhost:8080/bun:runtime";
Bun.activate(true);

var hmr = new HMR(635901064, "void-shouldnt-delete-call-expressions.js"), exports = hmr.exports;
(hmr._load = function() {
  var was_called = false;
  function thisShouldBeCalled() {
    was_called = true;
  }
  thisShouldBeCalled();
  function test() {
    if (!was_called)
      throw new Error("Expected thisShouldBeCalled to be called");
    return testDone(import.meta.url);
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
