#import "../Overlook/Overlook-Bridging-Header.h"
#import <sandbox.h>

// The legacy SDK functions remain available to C and to /usr/bin/sandbox-exec,
// but Swift imports their old deprecation range as unavailable. Keep this small
// compatibility wrapper entirely within the isolated test executable.
static inline int RecoveryFixtureEnterNetworkSandbox(void) {
    char *errorBuffer = NULL;
    int result = sandbox_init("(version 1) (allow default) (deny network*)", 0, &errorBuffer);
    sandbox_free_error(errorBuffer);
    return result;
}
