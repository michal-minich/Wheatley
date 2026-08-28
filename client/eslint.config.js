import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
    { ignores: ["dist/**", "node_modules/**"] },
    eslint.configs.recommended,
    ...tseslint.configs.strictTypeChecked,
    ...tseslint.configs.stylisticTypeChecked,
    {
        files: ["src/**/*.ts"],
        languageOptions: {
            parserOptions: {
                projectService: true,
                tsconfigRootDir: import.meta.dirname,
            },
        },
        rules: {
            "@typescript-eslint/consistent-type-definitions": ["error", "interface"],
            "@typescript-eslint/explicit-function-return-type": ["error", {
                allowExpressions: true,
                allowTypedFunctionExpressions: true,
            }],
            "@typescript-eslint/no-confusing-void-expression": "off",
            "@typescript-eslint/no-misused-promises": ["error", { checksVoidReturn: false }],
            "@typescript-eslint/no-non-null-assertion": "off",
            "@typescript-eslint/no-unnecessary-type-parameters": "off",
            "@typescript-eslint/no-unnecessary-condition": "error",
            "@typescript-eslint/restrict-template-expressions": ["error", { allowNumber: true }],
            "@typescript-eslint/return-await": ["error", "always"],
            "comma-dangle": ["error", "always-multiline"],
            curly: "off",
            indent: ["error", 4, { SwitchCase: 1 }],
            "max-len": ["error", 100],
            "no-console": "off",
            quotes: ["error", "double"],
        },
    },
);
