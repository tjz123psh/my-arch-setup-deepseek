-- ============================================
-- 自定义文件类型识别
-- 补齐 LSP 配置中使用、但 Neovim 默认不一定登记的 filetype
-- ============================================

vim.filetype.add({
  extension = {
    gotmpl = "gotmpl",
    mdx = "markdown.mdx",
  },
  filename = {
    [".gitlab-ci.yml"] = "yaml.gitlab",
    [".gitlab-ci.yaml"] = "yaml.gitlab",
    ["docker-compose.yml"] = "yaml.docker-compose",
    ["docker-compose.yaml"] = "yaml.docker-compose",
  },
  pattern = {
    [".*/docker%-compose%..*%.yml"] = "yaml.docker-compose",
    [".*/docker%-compose%..*%.yaml"] = "yaml.docker-compose",
    [".*/compose%.yml"] = "yaml.docker-compose",
    [".*/compose%.yaml"] = "yaml.docker-compose",
    [".*/templates/.*%.yml"] = "yaml.helm-values",
    [".*/templates/.*%.yaml"] = "yaml.helm-values",
  },
})
