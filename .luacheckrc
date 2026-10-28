std = "luajit"
globals = { "vim" }
files["**/*_spec.lua"] = {
  globals = { "describe", "it", "before_each", "after_each", "setup", "teardown", "assert" },
}
