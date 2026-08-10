import { fileURLToPath } from "node:url"

import { createDeepSeekGuardPlugin } from "../lib/deepseek-guard/plugin.js"

const configPath = fileURLToPath(new URL("../deepseek-guard.json", import.meta.url))

export const DeepSeekGuardPlugin = createDeepSeekGuardPlugin({ configPath })
export default DeepSeekGuardPlugin
