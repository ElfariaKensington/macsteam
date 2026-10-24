#include <assert.h>
#include <inttypes.h>
#include "../src/hooks/hook_manifest.c"

int main(int argc, char **argv) {
    uint64_t code = 7;
    assert(parse_manifest_code("13997152607566117948", &code) == 0 && code == UINT64_C(13997152607566117948));
    assert(parse_manifest_code("18446744073709551615", &code) == 0 && code == UINT64_MAX);
    assert(parse_manifest_code(" \r\n42\n", &code) == 0 && code == 42);
    const char *invalid[] = {"", "0", "-1", "+1", "18446744073709551616", "123garbage", "123 456", "502 Bad Gateway", "<html>403</html>", "1.0", "000000000000000000001"};
    for (size_t i = 0; i < sizeof(invalid)/sizeof(invalid[0]); ++i) {
        code = 7;
        assert(parse_manifest_code(invalid[i], &code) == -1 && code == 7);
    }
    assert(parse_manifest_code(NULL, &code) == -1);
    assert(parse_manifest_code("42", NULL) == -1);
    if (argc > 1 && !strcmp(argv[1], "--live")) {
        const uint64_t manifests[] = {UINT64_C(3651103799462409440), UINT64_C(2202889899553513457), UINT64_C(9044256803759256265)};
        for (size_t i = 0; i < sizeof(manifests)/sizeof(manifests[0]); ++i) {
            assert(fetch_manifest_code(manifests[i], &code) == 0 && code);
            printf("Portal 2 manifest %" PRIu64 ": provider OK\n", manifests[i]);
        }
    }
    puts("Manifest response checks passed");
}
