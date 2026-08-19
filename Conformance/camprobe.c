/* CIECAM02 differential (cmscam02.c).
 *
 * The four surrounds, a computed and a given degree of adaptation, and
 * two adapting luminances, each over a lattice of XYZ inputs run forward
 * to JCh and back, printed to fifteen significant digits so a one-ulp
 * drift in any step is visible.  The reverse of a forward result should
 * come back near the input; how near is printed rather than judged.
 */

#include <lcms2.h>
#include <stdio.h>
#include <math.h>

int main(void)
{
    static const cmsUInt32Number surrounds[] = { AVG_SURROUND, DIM_SURROUND, DARK_SURROUND, CUTSHEET_SURROUND, 99 };
    static const cmsFloat64Number ds[] = { D_CALCULATE, 0.5, 1.0 };
    static const cmsFloat64Number las[] = { 20.0, 200.0, 4.0 };
    unsigned si, di, li;
    int x, y, z;
    double worst = 0;

    for (si = 0; si < 5; si++)
        for (di = 0; di < 3; di++)
            for (li = 0; li < 3; li++) {
                cmsViewingConditions vc;
                cmsHANDLE h;
                vc.whitePoint.X = 0.9642; vc.whitePoint.Y = 1.0; vc.whitePoint.Z = 0.8249;
                vc.Yb = 20.0;
                vc.La = las[li];
                vc.surround = surrounds[si];
                vc.D_value = ds[di];
                h = cmsCIECAM02Init(NULL, &vc);
                printf("surround=%u D=%g La=%g handle=%d\n", surrounds[si], ds[di], las[li], h != NULL);
                if (h == NULL) continue;
                for (x = 0; x <= 4; x++)
                    for (y = 0; y <= 4; y++)
                        for (z = 0; z <= 4; z++) {
                            cmsCIEXYZ in, back;
                            cmsJCh jch;
                            double err;
                            in.X = x * 0.25 * 0.9642 + 0.001;
                            in.Y = y * 0.25 + 0.001;
                            in.Z = z * 0.25 * 0.8249 + 0.001;
                            cmsCIECAM02Forward(h, &in, &jch);
                            cmsCIECAM02Reverse(h, &jch, &back);
                            err = fabs(back.X - in.X) + fabs(back.Y - in.Y) + fabs(back.Z - in.Z);
                            if (err > worst) worst = err;
                            if (si == 0 && di == 0 && li == 0)
                                printf("  %.4f %.4f %.4f -> J=%.15g C=%.15g h=%.15g -> %.15g %.15g %.15g\n",
                                    in.X, in.Y, in.Z, jch.J, jch.C, jch.h, back.X, back.Y, back.Z);
                            else if ((x + y + z) % 3 == 0)
                                printf("  J=%.15g C=%.15g h=%.15g back=%.15g %.15g %.15g\n", jch.J, jch.C, jch.h, back.X, back.Y, back.Z);
                        }
                /* Achromatic and negative inputs take the other branches. */
                {
                    cmsCIEXYZ greys[4] = { { 0.5, 0.5, 0.5 }, { -0.1, 0.2, 0.3 }, { 0.3, 0.2, -0.1 }, { 0.0, 0.0, 0.0 } };
                    cmsJCh jch;
                    int i;
                    for (i = 0; i < 4; i++) {
                        cmsCIEXYZ back;
                        cmsCIECAM02Forward(h, &greys[i], &jch);
                        cmsCIECAM02Reverse(h, &jch, &back);
                        printf("  special %d: J=%.15g C=%.15g h=%.15g back=%.15g %.15g %.15g\n", i, jch.J, jch.C, jch.h, back.X, back.Y, back.Z);
                    }
                }
                /* Reverse of hand-made correlates, including a zero chroma. */
                {
                    cmsJCh given[3] = { { 50, 0, 100 }, { 80, 30, 45 }, { 20, 60, 300 } };
                    int i;
                    for (i = 0; i < 3; i++) {
                        cmsCIEXYZ out;
                        cmsCIECAM02Reverse(h, &given[i], &out);
                        printf("  given %d: %.15g %.15g %.15g\n", i, out.X, out.Y, out.Z);
                    }
                }
                cmsCIECAM02Done(h);
            }
    cmsCIECAM02Done(NULL);
    printf("worst round trip %.6g\n", worst);
    return 0;
}
