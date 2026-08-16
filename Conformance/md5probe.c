/* md5probe.c - the MD5 handle API, against the reference
 *
 * The profile ID an ICC profile carries is this digest, so a difference
 * here is a difference in every profile written.  Compiled against both
 * libraries and compared.
 *
 * The lengths walked are the ones a streaming hash gets wrong: either side
 * of the 56-byte padding threshold and the 64-byte block, and well past
 * several blocks.  The chunking loop matters as much as the lengths — the
 * same bytes fed in different-sized pieces must give the same digest, and
 * the reference's buffering is what this is measured against.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <stdio.h>

static void print_digest(const char* label, const cmsProfileID* id)
{
    printf("%-22s ", label);
    for (int i = 0; i < 16; i++) printf("%02x", id->ID8[i]);
    printf("\n");
}

int main(void)
{
    static cmsUInt8Number message[512];
    for (int i = 0; i < 512; i++)
        message[i] = (cmsUInt8Number) (i * 37 + (i >> 3));

    /* One shot, over the lengths where padding and blocking interact. */
    static const cmsUInt32Number lengths[] = {
        0, 1, 2, 55, 56, 57, 63, 64, 65, 111, 112, 113, 119, 120, 128, 255, 512
    };

    for (size_t i = 0; i < sizeof lengths / sizeof *lengths; i++) {
        cmsHANDLE h = cmsMD5alloc(NULL);
        cmsProfileID id;
        char label[32];

        if (h == NULL) { printf("alloc failed\n"); return 1; }
        cmsMD5add(h, message, lengths[i]);
        cmsMD5finish(&id, h);

        snprintf(label, sizeof label, "len %u", (unsigned) lengths[i]);
        print_digest(label, &id);
    }

    /* The same 512 bytes, fed in pieces of every awkward size: the digest
     * must not depend on how the caller split them up. */
    static const cmsUInt32Number chunks[] = { 1, 3, 7, 16, 31, 32, 55, 56, 63, 64, 65, 127 };

    for (size_t c = 0; c < sizeof chunks / sizeof *chunks; c++) {
        cmsHANDLE h = cmsMD5alloc(NULL);
        cmsProfileID id;
        char label[32];
        cmsUInt32Number offset = 0;

        if (h == NULL) { printf("alloc failed\n"); return 1; }
        while (offset < 512) {
            cmsUInt32Number take = chunks[c];
            if (offset + take > 512) take = 512 - offset;
            cmsMD5add(h, message + offset, take);
            offset += take;
        }
        cmsMD5finish(&id, h);

        snprintf(label, sizeof label, "chunked by %u", (unsigned) chunks[c]);
        print_digest(label, &id);
    }

    /* A zero-length add in the middle must change nothing. */
    {
        cmsHANDLE h = cmsMD5alloc(NULL);
        cmsProfileID id;

        cmsMD5add(h, message, 100);
        cmsMD5add(h, message, 0);
        cmsMD5add(h, message + 100, 100);
        cmsMD5finish(&id, h);
        print_digest("split with empty", &id);
    }

    printf("md5 probe OK\n");
    return 0;
}
