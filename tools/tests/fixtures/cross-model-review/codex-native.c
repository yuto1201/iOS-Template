#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
  char launcher[PATH_MAX];
  char fixture[PATH_MAX];
  if (realpath(argv[0], launcher) == NULL) {
    perror("realpath");
    return 127;
  }
  if (snprintf(fixture, sizeof(fixture), "%s/codex-fixture", dirname(launcher)) >= (int)sizeof(fixture)) {
    return 127;
  }
  execv(fixture, argv);
  perror("execv");
  return 127;
}
