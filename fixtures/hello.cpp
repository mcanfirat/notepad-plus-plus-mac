// Notepad++ for macOS — sample C++ file
#include <cstdio>
#include <vector>

/* A small struct */
struct Point { int x, y; };

int main(int argc, char **argv) {
    std::vector<Point> pts = {{1, 2}, {3, 4}};
    for (auto &p : pts) {
        printf("(%d, %d)\n", p.x, p.y);   // print each point
    }
    return 0;
}
