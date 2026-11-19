#include <stdio.h>

int main(void) {
    int a = 3, b = 2, c = 1;
    // Reads like "3 > 2 > 1", which is true in mathematics.
    printf("a > b > c is %d\n", a > b > c);
    return 0;
}
