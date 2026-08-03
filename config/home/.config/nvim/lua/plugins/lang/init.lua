-- =============================================================================
-- 语言专用配置聚合入口
-- =============================================================================
-- init.lua 被 lazy.nvim 自动加载，import 各语言的配置文件
-- =============================================================================

local specs = {}

local ok_cpp, cpp = pcall(require, "plugins.lang.cpp")
if not ok_cpp then
  cpp = {}
end
local ok_java, java = pcall(require, "plugins.lang.java")
if not ok_java then
  java = {}
end
local ok_go, go = pcall(require, "plugins.lang.go")
if not ok_go then
  go = {}
end
local ok_rust, rust = pcall(require, "plugins.lang.rust")
if not ok_rust then
  rust = {}
end

for _, spec in ipairs(cpp) do
  table.insert(specs, spec)
end
for _, spec in ipairs(java) do
  table.insert(specs, spec)
end
for _, spec in ipairs(go) do
  table.insert(specs, spec)
end
for _, spec in ipairs(rust) do
  table.insert(specs, spec)
end
return specs
