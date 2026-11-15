#include "../src/feats/schema_owners.c"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void test_extract(void) {
    const char *html =
        "<a href=\"https://steamcommunity.com/profiles/76561199013858464/\">author</a>"
        "<div data-miniprofile=\"1307837364\"></div>"
        "<a href=\"https://steamcommunity.com/profiles/76561199013858464\">duplicate</a>"
        "<a href=\"https://steamcommunity.com/id/vanityname\">vanity</a>"
        "<div data-miniprofile=\"76561199013858464\"></div>"
        "<div data-miniprofile=\"4294967296\"></div>"
        "<div data-miniprofile=\"notanumber\"></div>";

    app_owner_state_t state;
    memset(&state, 0, sizeof(state));
    state.appId = 1845250;

    uint64_t ids[8];
    int count = extract_steamids(html, ids, 8, &state);
    assert(count == 2);
    assert(ids[0] == 76561199013858464ULL);
    assert(ids[1] == STEAMID64_BASE + 1307837364ULL);

    state.blacklist[state.bl_count++] = ids[0];
    count = extract_steamids(html, ids, 8, &state);
    assert(count == 1);
    assert(ids[0] == STEAMID64_BASE + 1307837364ULL);

    assert(extract_steamids("", ids, 8, &state) == 0);
    assert(extract_steamids(NULL, ids, 8, &state) == 0);
}

int main(void) {
    sx_log_level = SX_LVL_WARN;
    test_extract();
    puts("Schema owner extraction checks passed");
    return 0;
}
