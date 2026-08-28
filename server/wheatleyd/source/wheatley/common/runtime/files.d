module wheatley.common.runtime.files;

import core.stdc.errno : EXDEV;

import std.file : FileException, copy, exists, remove, rename;

void moveFileReplacing(string source, string target)
{
    if (exists(target)) remove(target);
    try {
        rename(source, target);
    } catch (FileException error) {
        if (error.errno != EXDEV) throw error;
        copy(source, target);
        remove(source);
    }
}
