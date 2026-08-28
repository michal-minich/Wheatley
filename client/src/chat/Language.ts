import { Er } from "../core/Er";
import { requireChoice } from "../core/Json";

export type ChatLanguage = "en" | "sk" | "de";

export function parseChatLanguage(value: unknown, path = "JSON"): ChatLanguage {
    if (typeof value !== "string")
        return Er.contract(path);
    return requireChoice(value, path, ["en", "sk", "de"] as const);
}
