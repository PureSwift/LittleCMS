/* Gamut boundary descriptor differential (cmssm.c).
 *
 * Three descriptors: a sphere of radius 40 with a hole, a scattered
 * Lab cloud, and the testbed's "segment maxima" from a real sRGB round
 * trip.  Every sector is filled in from its neighbours after the
 * points go in, and a dense Lab lattice is then classified.  Sector
 * radii are hidden state, so the classification bits and their per-
 * point pattern are what is measured.
 */

#include <lcms2.h>
#include <stdio.h>
#include <string.h>

static const char* profile_dir = ".";

static cmsUInt32Number hash = 2166136261u;
static void mix(int bit) { hash = (hash ^ (cmsUInt32Number) bit) * 16777619u; }

static void classify(cmsHANDLE h, const char* name)
{
    int L, a, b, in = 0, out = 0;
    cmsUInt32Number local = 2166136261u;
    for (L = 0; L <= 100; L += 5)
        for (a = -128; a <= 128; a += 8)
            for (b = -128; b <= 128; b += 8) {
                cmsCIELab Lab = { L, a, b };
                int r = cmsGDBCheckPoint(h, &Lab) ? 1 : 0;
                local = (local ^ (cmsUInt32Number) r) * 16777619u;
                if (r) in++; else out++;
                mix(r);
            }
    printf("%s in=%d out=%d fp=%08x\n", name, in, out, local);
}

static void sphere(void)
{
    cmsHANDLE h = cmsGBDAlloc(NULL);
    int t, a;
    printf("sphere alloc=%d\n", h != NULL);
    for (t = 0; t <= 180; t += 3)
        for (a = 0; a < 360; a += 3) {
            /* Leave a hole so the modeller has work to do. */
            if (a > 90 && a < 150 && t > 60 && t < 120) continue;
            double th = t * 3.14159265358979 / 180.0, al = a * 3.14159265358979 / 180.0;
            cmsCIELab Lab;
            /* Some sectors carry two radii so the maximum rule is exercised. */
            double r = ((t + a) % 5 == 0) ? 40.0 : 30.0;
            Lab.L = 50 + r * ((th == 0) ? 1 : (double) __builtin_cos(th));
            Lab.a = r * __builtin_sin(th) * __builtin_sin(al);
            Lab.b = r * __builtin_sin(th) * __builtin_cos(al);
            if (!cmsGDBAddPoint(h, &Lab)) printf("add failed\n");
        }
    {
        /* The centre and a point outside the world. */
        cmsCIELab c = { 50, 0, 0 }, o = { 100, 127, -127 };
        printf("centre before=%d outer before=%d\n", cmsGDBCheckPoint(h, &c), cmsGDBCheckPoint(h, &o));
    }
    printf("compute=%d\n", cmsGDBCompute(h, 0));
    classify(h, "sphere");
    cmsGBDFree(h);
}

static void cloud(void)
{
    cmsHANDLE h = cmsGBDAlloc(NULL);
    cmsUInt32Number s = 12345;
    int i;
    for (i = 0; i < 4000; i++) {
        cmsCIELab Lab;
        s = s * 1103515245u + 12345u; Lab.L = (s >> 8) % 1001 / 10.0;
        s = s * 1103515245u + 12345u; Lab.a = (double) ((s >> 8) % 2561) / 10.0 - 128;
        s = s * 1103515245u + 12345u; Lab.b = (double) ((s >> 8) % 2561) / 10.0 - 128;
        if (!cmsGDBAddPoint(h, &Lab)) printf("add failed\n");
    }
    printf("compute=%d\n", cmsGDBCompute(h, 0));
    classify(h, "cloud");
    cmsGBDFree(h);
}

static void maxima(void)
{
    /* The testbed's third check: the sRGB gamut through a round trip. */
    cmsHPROFILE hsRGB = cmsCreate_sRGBProfile();
    cmsHPROFILE hLab = cmsCreateLab4Profile(NULL);
    cmsHTRANSFORM xform = cmsCreateTransform(hsRGB, TYPE_RGB_8, hLab, TYPE_Lab_DBL, INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOCACHE);
    cmsHANDLE h = cmsGBDAlloc(NULL);
    int r, g, b;
    cmsCloseProfile(hsRGB);
    cmsCloseProfile(hLab);
    for (r = 0; r < 256; r += 5)
        for (g = 0; g < 256; g += 5)
            for (b = 0; b < 256; b += 5) {
                cmsUInt8Number rgb[3] = { (cmsUInt8Number) r, (cmsUInt8Number) g, (cmsUInt8Number) b };
                cmsCIELab Lab;
                cmsDoTransform(xform, rgb, &Lab, 1);
                if (!cmsGDBAddPoint(h, &Lab)) printf("add failed\n");
            }
    printf("compute=%d\n", cmsGDBCompute(h, 0));
    classify(h, "srgb");
    /* Every sRGB colour must be inside its own boundary. */
    {
        int miss = 0;
        for (r = 0; r < 256; r += 10)
            for (g = 0; g < 256; g += 10)
                for (b = 0; b < 256; b += 10) {
                    cmsUInt8Number rgb[3] = { (cmsUInt8Number) r, (cmsUInt8Number) g, (cmsUInt8Number) b };
                    cmsCIELab Lab;
                    cmsDoTransform(xform, rgb, &Lab, 1);
                    if (!cmsGDBCheckPoint(h, &Lab)) miss++;
                }
        printf("srgb misses=%d\n", miss);
    }
    cmsGBDFree(h);
    cmsDeleteTransform(xform);
}

int main(int argc, char** argv)
{
    if (argc > 1) profile_dir = argv[1];
    (void) profile_dir;
    /* Null handles are tolerated by free only. */
    cmsGBDFree(NULL);
    sphere();
    cloud();
    maxima();
    printf("hash=%08x\n", hash);
    return 0;
}
