function fail(message: string, detail?: string): never {
    throw new Error(detail === undefined ? message : `${message} ${detail}`);
}

export const Er = {
    internal: (detail?: string): never => fail("App internal error.", detail),
    contract: (detail?: string): never => fail(
        "Data received from network or storage are incorrect.",
        detail,
    ),
    io: (detail?: string): never => fail("Network, operating system or hardware error.", detail),
};
