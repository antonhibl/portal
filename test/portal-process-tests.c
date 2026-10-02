/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The raw Darwin argument area is otherwise hard to induce safely in a process. */
#include "../native/Processes/Processes.c"
#include <assert.h>

static void encoded_string_is(const char *input, const char *expected)
{
    char *json = NULL;
    size_t length = 0;
    FILE *out = open_memstream(&json, &length);
    assert(out);
    string(out, input);
    assert(!fclose(out));
    assert(!strcmp(json, expected));
    free(json);
}

int main(void)
{
    portal_string variable = {"PORTAL_TERMINAL", 15};
    struct arguments parsed;
    char bytes[256] = {0};
    int argc = 2;
    memcpy(bytes, &argc, sizeof argc);
    const char area[] = "/bin/node\0\0node\0/bin/claude\0\0\0PORTAL_TERMINAL=42/terminal:9\0X=y\0";
    memcpy(bytes + sizeof argc, area, sizeof area);
    assert(parse_arguments(bytes, sizeof argc + sizeof area, variable, &parsed));
    assert(parsed.argc == 2 && !strcmp(parsed.argv, "node"));
    assert(!strcmp(parsed.value, "42/terminal:9"));
    /* Truncations, malformed argc, missing NULs, a marker prefix and no marker. */
    for (size_t n = 0; n < sizeof argc + 24; n++)
        assert(!parse_arguments(bytes, n, variable, &parsed));
    assert(!parse_arguments(bytes, sizeof bytes, (portal_string) {"PORTAL", 6}, &parsed));
    argc = -1; memcpy(bytes, &argc, sizeof argc);
    assert(!parse_arguments(bytes, sizeof bytes, variable, &parsed));
    memset(bytes, 'x', sizeof bytes);
    argc = 1; memcpy(bytes, &argc, sizeof argc);
    assert(!parse_arguments(bytes, sizeof bytes, variable, &parsed));
    /* JSON strings must escape control bytes and quotes in paths and markers. */
    char *json = NULL;
    size_t length = 0;
    FILE *out = open_memstream(&json, &length);
    assert(out);
    string(out, "a\n\"\\é");
    assert(!fclose(out));
    assert(!strcmp(json, "\"a\\u000a\\\"\\\\é\""));
    free(json);
    /* Process strings are arbitrary POSIX bytes. Preserve Unicode, replacing
       each invalid byte without eating adjacent ASCII or valid code points. */
    encoded_string_is("é日本🙂", "\"é日本🙂\"");
    encoded_string_is("before\xff" "after", "\"before\\ufffdafter\"");
    encoded_string_is("\x80\xc0\xaf", "\"\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xe2\x82", "\"\\ufffd\\ufffd\"");
    encoded_string_is("\xe0\x80\x80", "\"\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xf0\x80\x80\x80", "\"\\ufffd\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xed\xa0\x80", "\"\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xf4\x90\x80\x80", "\"\\ufffd\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xe2" "Aé\xff\\\"", "\"\\ufffdAé\\ufffd\\\\\\\"\"");
    encoded_string_is("\xc2\x80\xe0\xa0\x80\xed\x9f\xbf\xf4\x8f\xbf\xbf",
                      "\"\xc2\x80\xe0\xa0\x80\xed\x9f\xbf\xf4\x8f\xbf\xbf\"");
    portal_text result = {0}, error = {0};
    assert(!portal_process_snapshot((portal_string) {"bad=name", 8}, &result, &error));
    free(error.data);
    /* Real snapshot with an absent marker is an empty array, not an error. */
    assert(portal_process_snapshot((portal_string) {"PORTAL_TEST_ABSENT_MARKER", 25}, &result, &error));
    assert(!strcmp(result.data, "[]"));
    free(result.data);
    return 0;
}
