module wheatley.common.json.object;

public import wheatley.common.json.write;

// Compatibility aliases while call sites move to jsonText / jsonBool / jsonLong / jsonRaw.
alias jsonStringField = jsonText;
alias jsonBoolField = jsonBool;
alias jsonLongField = jsonLong;
alias jsonUlongField = jsonUlong;
alias jsonRawField = jsonRaw;
alias json = jsonQuote;
