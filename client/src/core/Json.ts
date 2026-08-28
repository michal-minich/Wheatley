import { Er } from "./Er";

type JsonRecord = Readonly<Record<string, unknown>>;

export class JsonObject {
    readonly #value: JsonRecord;
    readonly label: string;

    private constructor(value: JsonRecord, label: string) {
        this.#value = value;
        this.label = label;
    }

    static from(value: unknown, label = "JSON"): JsonObject {
        if (typeof value !== "object" || value === null || Array.isArray(value))
            return Er.contract(label);
        return new JsonObject(value as JsonRecord, label);
    }

    static parse(text: string, label = "JSON"): JsonObject {
        return JsonObject.from(parseJson(text, label), label);
    }

    get opt(): JsonOpt {
        return new JsonOpt(this);
    }

    choice<T extends string>(name: string, allowed: readonly T[]): T {
        return requireChoice(this.string(name), this.path(name), allowed);
    }

    string(name: string): string {
        const value = this.#value[name];
        if (typeof value !== "string")
            return Er.contract(this.path(name));
        return value;
    }

    nonEmpty(name: string): string {
        const value = this.string(name);
        if (value.length === 0)
            return Er.contract(this.path(name));
        return value;
    }

    boolean(name: string): boolean {
        const value = this.#value[name];
        if (typeof value !== "boolean")
            return Er.contract(this.path(name));
        return value;
    }

    number(name: string, minimum?: number, maximum?: number): number {
        const value = this.#value[name];
        if (typeof value !== "number" || !Number.isFinite(value))
            return Er.contract(this.path(name));
        if (minimum !== undefined && value < minimum)
            return Er.contract(this.path(name));
        if (maximum !== undefined && value > maximum)
            return Er.contract(this.path(name));
        return value;
    }

    /** Required finite safe integer, optionally ranged. */
    integer(name: string, minimum?: number, maximum?: number): number {
        const value = this.number(name, minimum, maximum);
        if (!Number.isSafeInteger(value))
            return Er.contract(this.path(name));
        return value;
    }

    positiveInteger(name: string, maximum?: number): number {
        return this.integer(name, 1, maximum);
    }

    nonNegativeInteger(name: string, maximum?: number): number {
        return this.integer(name, 0, maximum);
    }

    value(name: string): unknown {
        return this.#value[name];
    }

    object(name: string): JsonObject {
        return JsonObject.from(this.#value[name], this.path(name));
    }

    array(name: string): readonly unknown[] {
        return jsonArray(this.#value[name], this.path(name));
    }

    path(name: string): string {
        return `${this.label}.${name}`;
    }
}

class JsonOpt {
    readonly #parent: JsonObject;

    constructor(parent: JsonObject) {
        this.#parent = parent;
    }

    string(name: string): string | undefined {
        const value = this.#parent.value(name);
        if (value === undefined || value === null)
            return undefined;
        if (typeof value !== "string")
            return Er.contract(this.#parent.path(name));
        return value;
    }

    /** Absent → `""`. Present wrong type still fails. */
    stringOrEmpty(name: string): string {
        return this.string(name) ?? "";
    }

    boolean(name: string): boolean | undefined {
        const value = this.#parent.value(name);
        if (value === undefined || value === null)
            return undefined;
        if (typeof value !== "boolean")
            return Er.contract(this.#parent.path(name));
        return value;
    }

    number(name: string, minimum?: number, maximum?: number): number | undefined {
        const value = this.#parent.value(name);
        if (value === undefined || value === null)
            return undefined;
        if (typeof value !== "number" || !Number.isFinite(value))
            return Er.contract(this.#parent.path(name));
        if (minimum !== undefined && value < minimum)
            return Er.contract(this.#parent.path(name));
        if (maximum !== undefined && value > maximum)
            return Er.contract(this.#parent.path(name));
        return value;
    }

    integer(name: string, minimum?: number, maximum?: number): number | undefined {
        const value = this.number(name, minimum, maximum);
        if (value === undefined)
            return undefined;
        if (!Number.isSafeInteger(value))
            return Er.contract(this.#parent.path(name));
        return value;
    }

    positiveInteger(name: string, maximum?: number): number | undefined {
        return this.integer(name, 1, maximum);
    }

    nonNegativeInteger(name: string, maximum?: number): number | undefined {
        return this.integer(name, 0, maximum);
    }

    object(name: string): JsonObject | undefined {
        const value = this.#parent.value(name);
        return value === undefined || value === null
            ? undefined
            : JsonObject.from(value, this.#parent.path(name));
    }

    choice<T extends string>(name: string, allowed: readonly T[]): T | undefined {
        const value = this.string(name);
        if (value === undefined)
            return undefined;
        return requireChoice(value, this.#parent.path(name), allowed);
    }
}

export function requireChoice<T extends string>(
    value: string,
    allowed: readonly T[],
): T;
export function requireChoice<T extends string>(
    value: string,
    path: string,
    allowed: readonly T[],
): T;
export function requireChoice<T extends string>(
    value: string,
    pathOrAllowed: string | readonly T[],
    allowed?: readonly T[],
): T {
    if (typeof pathOrAllowed !== "string") {
        if (pathOrAllowed.includes(value as T))
            return value as T;
        return Er.contract("JSON");
    }
    if (allowed!.includes(value as T))
        return value as T;
    return Er.contract(pathOrAllowed.length ? pathOrAllowed : "JSON");
}

export function parseJson(text: string, label = "JSON"): unknown {
    try {
        return JSON.parse(text) as unknown;
    } catch {
        return Er.contract(label);
    }
}

export function jsonArray(value: unknown, label = "JSON"): readonly unknown[] {
    if (!Array.isArray(value))
        return Er.contract(label);
    return value;
}
