/* Emits the reference's parametric curve values as a Swift fixture. */
#include "lcms2.h"
#include <stdio.h>

int main(void)
{
    struct { int type; int n; double p[7]; } cases[] = {
        { 1,   1, { 2.2 } },
        { 1,   1, { 1.0 } },
        { 1,   1, { 0.0 } },
        { 2,   3, { 2.4, 0.9, 0.1 } },
        { 2,   3, { 2.4, 0.0, 0.1 } },
        { 3,   4, { 2.4, 0.9, 0.1, 0.05 } },
        { 4,   5, { 2.4, 1.0/1.055, 0.055/1.055, 1.0/12.92, 0.04045 } },
        { 5,   7, { 2.4, 0.9, 0.1, 0.05, 0.2, 0.01, 0.02 } },
        { 6,   4, { 2.4, 0.9, 0.1, 0.05 } },
        { 6,   4, { 1.0, 0.9, 0.1, 0.05 } },
        { 7,   5, { 2.0, 0.5, 1.5, 0.2, 0.1 } },
        { 8,   5, { 0.7, 2.0, 1.3, 0.1, 0.05 } },
        { 108, 1, { 2.0 } },
        { 109, 1, { 3.0 } },
    };
    const int n = (int) (sizeof cases / sizeof *cases);

    printf("// Generated from the reference by scripts/gen_curve_fixture.sh — do not edit.\n");
    printf("//\n");
    printf("// Each row is a parametric type, its parameters, an input, and the\n");
    printf("// value the reference produces.  Observed, not remembered.\n\n");
    printf("let parametricExpectations: [(type: Int32, params: [Double], input: Double, output: Double)] = [\n");

    for (int i = 0; i < n; i++) {
        for (int s = -2; s <= 12; s++) {
            double r = s / 10.0;   /* includes negatives and values past 1 */
            for (int sign = 1; sign >= -1; sign -= 2) {
                int type = cases[i].type * sign;
                cmsToneCurve* c = cmsBuildParametricToneCurve(NULL, type, cases[i].p);
                if (!c) continue;
                /* The curve evaluates the parametric function directly for
                 * a single-segment curve built this way. */
                /* The reference narrows the input to float before it
                 * widens it again inside the curve, so the point actually
                 * evaluated is not r but this.  Recording r would compare
                 * two different questions. */
                cmsFloat32Number rf = (cmsFloat32Number) r;
                double v = cmsEvalToneCurveFloat(c, rf);
                printf("    (%d, [", type);
                for (int k = 0; k < cases[i].n; k++)
                    printf("%s%.17g", k ? ", " : "", cases[i].p[k]);
                printf("], %.17g, ", (double) rf);
                if (v != v) printf("Double.nan),\n");
                else if (v > 1e300) printf("Double.infinity),\n");
                else if (v < -1e300) printf("-Double.infinity),\n");
                else printf("%.17g),\n", v);
                cmsFreeToneCurve(c);
            }
        }
    }
    printf("]\n");
    return 0;
}
