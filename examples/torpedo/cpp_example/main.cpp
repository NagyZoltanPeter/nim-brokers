/**
 * Torpedo Duel — modern C++ text UI example
 * ==========================================
 * Demonstrates consuming the torpedolib Nim dynamic library through
 * the generated C++ wrapper class.
 *
 * The C++ app mirrors the Python example: it creates two independent
 * library contexts, bootstraps the duel, then steps back and renders
 * a terminal UI while the captains fight autonomously inside Nim.
 *
 * Build from the repository root:
 *   nimble buildTorpedoExampleCpp
 *
 * Run from the repository root:
 *   nimble runTorpedoExampleCpp
 *   nimble runTorpedoExampleCpp -- --fast
 */

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <conio.h>
#else
#include <termios.h>
#include <unistd.h>
#include <sys/select.h>
#endif

#include "torpedolib.h"

using namespace torpedolib;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

struct Config {
    int seedRed       = 101;
    int seedBlue      = 202;
    int boardSize     = 8;
    bool starterIsRed = true;
    bool fast         = false;

    double refreshDelay() const { return fast ? 0.05  : 0.18;  }
    int    turnDelayMs()  const { return fast ? 120   : 650;   }
    double endDelay()     const { return fast ? 0.20  : 1.0;   }
};

static void printUsage(const char* prog) {
    std::fprintf(stderr,
        "Usage: %s [OPTIONS]\n"
        "\n"
        "Run the Torpedo Duel text UI\n"
        "\n"
        "Options:\n"
        "  --fast              reduce delays for quicker runs\n"
        "  --seed-red N        seed for Red Fleet (default: 101)\n"
        "  --seed-blue N       seed for Blue Fleet (default: 202)\n"
        "  --board-size N      board size (default: 8)\n"
        "  --starter red|blue  which fleet opens the duel (default: red)\n"
        "  --help              show this message and exit\n"
        "\n"
        "Controls:\n"
        "  q / Q               quit immediately\n", prog);
}

static Config parseArgs(int argc, char* argv[]) {
    Config cfg;
    for (int i = 1; i < argc; ++i) {
        std::string_view arg(argv[i]);
        if (arg == "--help" || arg == "-h") {
            printUsage(argv[0]);
            std::exit(0);
        }
        else if (arg == "--fast")                            cfg.fast = true;
        else if (arg == "--starter" && i + 1 < argc)  { cfg.starterIsRed = std::string_view(argv[++i]) != "blue"; }
        else if (arg == "--seed-red" && i + 1 < argc)   cfg.seedRed = std::atoi(argv[++i]);
        else if (arg == "--seed-blue" && i + 1 < argc)  cfg.seedBlue = std::atoi(argv[++i]);
        else if (arg == "--board-size" && i + 1 < argc)  cfg.boardSize = std::atoi(argv[++i]);
    }
    return cfg;
}

// ---------------------------------------------------------------------------
// Non-blocking keyboard input (portable: macOS, Linux, Windows)
// ---------------------------------------------------------------------------

class RawTerminal {
public:
    RawTerminal() noexcept {
#ifdef _WIN32
        active_ = true;  // _kbhit/_getch need no setup
#else
        if (::isatty(STDIN_FILENO)) {
            ::tcgetattr(STDIN_FILENO, &oldSettings_);
            struct termios raw = oldSettings_;
            raw.c_lflag &= ~static_cast<tcflag_t>(ICANON | ECHO);
            raw.c_cc[VMIN] = 0;
            raw.c_cc[VTIME] = 0;
            ::tcsetattr(STDIN_FILENO, TCSANOW, &raw);
            active_ = true;
        }
#endif
    }

    ~RawTerminal() { restore(); }

    RawTerminal(const RawTerminal&) = delete;
    RawTerminal& operator=(const RawTerminal&) = delete;

    void restore() noexcept {
#ifndef _WIN32
        if (active_) {
            ::tcsetattr(STDIN_FILENO, TCSADRAIN, &oldSettings_);
            active_ = false;
        }
#else
        active_ = false;
#endif
    }

    /// Returns the key character if one is available, or '\0' if none.
    char keyPressed() const noexcept {
        if (!active_) return '\0';
#ifdef _WIN32
        if (_kbhit())
            return static_cast<char>(_getch());
        return '\0';
#else
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(STDIN_FILENO, &fds);
        struct timeval tv = {0, 0};
        if (::select(STDIN_FILENO + 1, &fds, nullptr, nullptr, &tv) > 0) {
            char ch = '\0';
            if (::read(STDIN_FILENO, &ch, 1) == 1)
                return ch;
        }
        return '\0';
#endif
    }

private:
#ifndef _WIN32
    struct termios oldSettings_ {};
#endif
    bool active_ = false;
};

// ---------------------------------------------------------------------------
// Thread-safe event log
// ---------------------------------------------------------------------------

class EventLog {
public:
    explicit EventLog(size_t maxEntries = 24) : maxEntries_(maxEntries) {}

    void push(std::string msg) {
        std::lock_guard<std::mutex> lock(mu_);
        entries_.push_back(std::move(msg));
        while (entries_.size() > maxEntries_)
            entries_.pop_front();
    }

    std::deque<std::string> snapshot() const {
        std::lock_guard<std::mutex> lock(mu_);
        return entries_;
    }

    std::string last() const {
        std::lock_guard<std::mutex> lock(mu_);
        return entries_.empty() ? std::string() : entries_.back();
    }

private:
    mutable std::mutex mu_;
    std::deque<std::string> entries_;
    size_t maxEntries_;
};

// ---------------------------------------------------------------------------
// Board symbols
// ---------------------------------------------------------------------------

static char ownSymbol(int32_t code) {
    switch (code) {
        case 0: return '.';  // EnemyUnknown (unused on own board)
        case 1: return '.';  // OwnWater
        case 2: return 'S';  // OwnShip
        case 3: return 'o';  // ShotMiss
        case 4: return 'x';  // ShotHit
        case 5: return '*';  // ShotSunk
        default: return '?';
    }
}

static char enemySymbol(int32_t code) {
    switch (code) {
        case 0: return '.';  // EnemyUnknown
        case 1: return '.';  // OwnWater
        case 2: return '!';  // OwnShip — should never appear on enemy chart
        case 3: return 'o';  // ShotMiss
        case 4: return 'x';  // ShotHit
        case 5: return '*';  // ShotSunk
        default: return '?';
    }
}

// ---------------------------------------------------------------------------
// Coordinate label
// ---------------------------------------------------------------------------

static std::string coordLabel(int32_t row, int32_t col) {
    char buf[8];
    std::snprintf(buf, sizeof(buf), "%c%d", 'A' + col, row + 1);
    return buf;
}

// ---------------------------------------------------------------------------
// ANSI helpers
// ---------------------------------------------------------------------------

namespace ansi {
    constexpr const char* reset     = "\033[0m";
    constexpr const char* bold      = "\033[1m";
    constexpr const char* dim       = "\033[2m";
    constexpr const char* red       = "\033[31m";
    constexpr const char* green     = "\033[32m";
    constexpr const char* yellow    = "\033[33m";
    constexpr const char* blue      = "\033[34m";
    constexpr const char* cyan      = "\033[36m";
    constexpr const char* white     = "\033[37m";
    constexpr const char* bgRed     = "\033[41m";
    constexpr const char* bgBlue    = "\033[44m";

    inline void clearScreen() { std::fputs("\033[2J\033[H", stdout); }
    inline void moveTo(int row, int col) { std::fprintf(stdout, "\033[%d;%dH", row, col); }
}

// ---------------------------------------------------------------------------
// Colorized cell rendering
// ---------------------------------------------------------------------------

static void printOwnCell(int32_t code) {
    switch (code) {
        case 2: std::fputs(ansi::bold, stdout); std::fputs(ansi::green, stdout);
                std::fputc('S', stdout); std::fputs(ansi::reset, stdout); break;
        case 3: std::fputs(ansi::dim, stdout);
                std::fputc('o', stdout); std::fputs(ansi::reset, stdout); break;
        case 4: std::fputs(ansi::bold, stdout); std::fputs(ansi::yellow, stdout);
                std::fputc('x', stdout); std::fputs(ansi::reset, stdout); break;
        case 5: std::fputs(ansi::bold, stdout); std::fputs(ansi::red, stdout);
                std::fputc('*', stdout); std::fputs(ansi::reset, stdout); break;
        default: std::fputc('.', stdout); break;
    }
}

static void printEnemyCell(int32_t code) {
    switch (code) {
        case 2: std::fputs(ansi::bold, stdout); std::fputs(ansi::red, stdout);
                std::fputc('!', stdout); std::fputs(ansi::reset, stdout); break;
        case 3: std::fputs(ansi::dim, stdout);
                std::fputc('o', stdout); std::fputs(ansi::reset, stdout); break;
        case 4: std::fputs(ansi::bold, stdout); std::fputs(ansi::yellow, stdout);
                std::fputc('x', stdout); std::fputs(ansi::reset, stdout); break;
        case 5: std::fputs(ansi::bold, stdout); std::fputs(ansi::red, stdout);
                std::fputc('*', stdout); std::fputs(ansi::reset, stdout); break;
        default: std::fputc('.', stdout); break;
    }
}

// ---------------------------------------------------------------------------
// Board rendering
// ---------------------------------------------------------------------------

static void printBoard(const std::vector<PublicCell>& cells, int32_t size, bool own) {
    // Build grid
    std::vector<std::vector<int32_t>> grid(size, std::vector<int32_t>(size, 0));
    for (const auto& c : cells)
        if (c.row < size && c.col < size)
            grid[c.row][c.col] = c.stateCode;

    // Header
    std::fputs("  ", stdout);
    for (int c = 0; c < size; ++c)
        std::fprintf(stdout, " %c", 'A' + c);
    std::fputc('\n', stdout);

    // Rows
    for (int r = 0; r < size; ++r) {
        std::fprintf(stdout, "%d ", r + 1);
        for (int c = 0; c < size; ++c) {
            std::fputc(' ', stdout);
            if (own)
                printOwnCell(grid[r][c]);
            else
                printEnemyCell(grid[r][c]);
        }
        std::fputc('\n', stdout);
    }
}

// ---------------------------------------------------------------------------
// Fleet status rendering
// ---------------------------------------------------------------------------

static void printFleet(const std::vector<ShipStatus>& fleet) {
    for (const auto& s : fleet) {
        std::fprintf(stdout, "  %-12s ", s.name.c_str());
        if (s.sunk)
            std::fprintf(stdout, "%ssunk%s\n", ansi::red, ansi::reset);
        else
            std::fprintf(stdout, "%d/%d\n", s.hits, s.length);
    }
}

// ---------------------------------------------------------------------------
// Side-by-side panel rendering
// ---------------------------------------------------------------------------

static void printSideBySide(
    const std::function<void()>& leftFn,
    const std::function<void()>& rightFn,
    int leftWidth,
    int gap = 4)
{
    // For simplicity, we render each side sequentially with column offsets.
    // The generated header gives us all data — we just lay it out.
    (void)leftFn; (void)rightFn; (void)leftWidth; (void)gap;
}

// ---------------------------------------------------------------------------
// Full screen draw
// ---------------------------------------------------------------------------

static void drawScreen(
    const GetPublicBoardRequestResult& red,
    const GetPublicBoardRequestResult& blue,
    const EventLog& log,
    const std::string& banner,
    const Config& cfg)
{
    ansi::clearScreen();

    // Title bar
    std::fprintf(stdout, "%s%s Torpedo Duel %s", ansi::bold, ansi::white, ansi::reset);
    std::fprintf(stdout, "  %srefresh=%.2fs | backend duel is self-driven%s\n",
                 ansi::dim, cfg.refreshDelay(), ansi::reset);
    std::fprintf(stdout, "%s%s%s\n\n", ansi::cyan, banner.c_str(), ansi::reset);

    const int bsz = red.boardSize;
    const int boardWidth = 2 + 2 * bsz + 1;  // "N " + " X" * bsz
    const int panelGap = 6;

    // Helper: print N spaces
    auto spaces = [](int n) { for (int i = 0; i < n; ++i) std::fputc(' ', stdout); };

    // ── Board headers ──
    std::fprintf(stdout, "%s%s RED FLEET%s", ansi::bold, ansi::red, ansi::reset);
    spaces(boardWidth - 3);   // align to panel gap
    std::fprintf(stdout, "%s%s BLUE FLEET%s\n", ansi::bold, ansi::blue, ansi::reset);

    // ── Own Waters side by side ──
    std::fprintf(stdout, " Own Waters");
    spaces(boardWidth - 5);
    std::fprintf(stdout, " Own Waters\n");

    // Build grids
    auto makeGrid = [](const std::vector<PublicCell>& cells, int32_t size) {
        std::vector<std::vector<int32_t>> g(size, std::vector<int32_t>(size, 0));
        for (const auto& c : cells)
            if (c.row < size && c.col < size)
                g[c.row][c.col] = c.stateCode;
        return g;
    };

    auto redOwnGrid   = makeGrid(red.ownCells,   bsz);
    auto redEnemyGrid  = makeGrid(red.enemyCells,  bsz);
    auto blueOwnGrid  = makeGrid(blue.ownCells,  bsz);
    auto blueEnemyGrid = makeGrid(blue.enemyCells, bsz);

    auto printGridHeader = [&](int size) {
        std::fputs("  ", stdout);
        for (int c = 0; c < size; ++c)
            std::fprintf(stdout, " %c", 'A' + c);
    };

    auto printGridRow = [](const std::vector<int32_t>& row, int rowIdx, bool own) {
        std::fprintf(stdout, "%d ", rowIdx + 1);
        for (size_t c = 0; c < row.size(); ++c) {
            std::fputc(' ', stdout);
            if (own) printOwnCell(row[c]);
            else     printEnemyCell(row[c]);
        }
    };

    // Column headers
    printGridHeader(bsz);
    spaces(panelGap);
    printGridHeader(bsz);
    std::fputc('\n', stdout);

    // Own board rows
    for (int r = 0; r < bsz; ++r) {
        printGridRow(redOwnGrid[r], r, true);
        spaces(panelGap);
        printGridRow(blueOwnGrid[r], r, true);
        std::fputc('\n', stdout);
    }

    std::fputc('\n', stdout);

    // ── Enemy Charts side by side ──
    std::fprintf(stdout, " Enemy Chart");
    spaces(boardWidth - 6);
    std::fprintf(stdout, " Enemy Chart\n");

    printGridHeader(bsz);
    spaces(panelGap);
    printGridHeader(bsz);
    std::fputc('\n', stdout);

    for (int r = 0; r < bsz; ++r) {
        printGridRow(redEnemyGrid[r], r, false);
        spaces(panelGap);
        printGridRow(blueEnemyGrid[r], r, false);
        std::fputc('\n', stdout);
    }

    std::fputc('\n', stdout);

    // ── Fleet status side by side ──
    auto redFleetLines = [&]() -> std::vector<std::string> {
        std::vector<std::string> lines;
        for (const auto& s : red.fleet) {
            char buf[64];
            if (s.sunk)
                std::snprintf(buf, sizeof(buf), "  %-12s sunk", s.name.c_str());
            else
                std::snprintf(buf, sizeof(buf), "  %-12s %d/%d", s.name.c_str(), s.hits, s.length);
            lines.emplace_back(buf);
        }
        return lines;
    };
    auto blueFleetLines = [&]() -> std::vector<std::string> {
        std::vector<std::string> lines;
        for (const auto& s : blue.fleet) {
            char buf[64];
            if (s.sunk)
                std::snprintf(buf, sizeof(buf), "  %-12s sunk", s.name.c_str());
            else
                std::snprintf(buf, sizeof(buf), "  %-12s %d/%d", s.name.c_str(), s.hits, s.length);
            lines.emplace_back(buf);
        }
        return lines;
    };

    auto rfl = redFleetLines();
    auto bfl = blueFleetLines();
    int fleetWidth = boardWidth + 2;

    std::fprintf(stdout, "%s RED STATUS%s", ansi::bold, ansi::reset);
    spaces(fleetWidth - 4);
    std::fprintf(stdout, "%s BLUE STATUS%s\n", ansi::bold, ansi::reset);

    size_t maxFleet = std::max(rfl.size(), bfl.size());
    for (size_t i = 0; i < maxFleet; ++i) {
        if (i < rfl.size()) {
            // Colorize sunk ships
            if (red.fleet[i].sunk) {
                std::fprintf(stdout, "  %-12s %ssunk%s", red.fleet[i].name.c_str(), ansi::red, ansi::reset);
                spaces(fleetWidth - 18);
            } else {
                std::fprintf(stdout, "  %-12s %d/%d", red.fleet[i].name.c_str(), red.fleet[i].hits, red.fleet[i].length);
                spaces(fleetWidth - 18);
            }
        } else {
            spaces(fleetWidth + 2);
        }
        if (i < bfl.size()) {
            if (blue.fleet[i].sunk)
                std::fprintf(stdout, "  %-12s %ssunk%s", blue.fleet[i].name.c_str(), ansi::red, ansi::reset);
            else
                std::fprintf(stdout, "  %-12s %d/%d", blue.fleet[i].name.c_str(), blue.fleet[i].hits, blue.fleet[i].length);
        }
        std::fputc('\n', stdout);
    }

    std::fputc('\n', stdout);

    // ── Meta info ──
    auto outcomeStr = [](bool gameOver, bool hasWon) -> const char* {
        if (!gameOver) return "active";
        return hasWon ? "won" : "lost";
    };

    std::fprintf(stdout, "%s RED META%s", ansi::bold, ansi::reset);
    spaces(fleetWidth - 2);
    std::fprintf(stdout, "%s BLUE META%s\n", ansi::bold, ansi::reset);

    auto printMetaRow = [&](const char* label,
                            const std::string& redVal,
                            const std::string& blueVal) {
        std::fprintf(stdout, "  %-10s %-8s", label, redVal.c_str());
        spaces(fleetWidth - 20);
        std::fprintf(stdout, "  %-10s %s\n", label, blueVal.c_str());
    };

    printMetaRow("AI",       red.aiMode,                    blue.aiMode);
    printMetaRow("Delay",    std::to_string(red.turnDelayMs) + " ms",
                             std::to_string(blue.turnDelayMs) + " ms");
    printMetaRow("Placed",   red.fleetPlaced ? "yes" : "no",  blue.fleetPlaced ? "yes" : "no");
    printMetaRow("Linked",   red.linked      ? "yes" : "no",  blue.linked      ? "yes" : "no");
    printMetaRow("Started",  red.started     ? "yes" : "no",  blue.started     ? "yes" : "no");
    printMetaRow("Opponent", std::to_string(red.opponentCtx), std::to_string(blue.opponentCtx));
    printMetaRow("Outcome",  outcomeStr(red.gameOver, red.hasWon),
                             outcomeStr(blue.gameOver, blue.hasWon));

    std::fputc('\n', stdout);

    // ── Scoreboard ──
    std::fprintf(stdout, "%sScoreboard%s\n", ansi::bold, ansi::reset);
    std::fprintf(stdout, "  Red  fired=%-2d received=%-2d  |  Blue fired=%-2d received=%-2d\n\n",
                 red.totalShotsFired, red.totalShotsReceived,
                 blue.totalShotsFired, blue.totalShotsReceived);

    // ── Event log ──
    std::fprintf(stdout, "%sEvent Log%s\n", ansi::bold, ansi::reset);
    auto entries = log.snapshot();
    for (const auto& line : entries)
        std::fprintf(stdout, "  %s- %s%s\n", ansi::dim, line.c_str(), ansi::reset);

    std::fprintf(stdout, "\n%sPress q to quit%s\n", ansi::dim, ansi::reset);

    std::fflush(stdout);
}

// ---------------------------------------------------------------------------
// Event listener registration
// ---------------------------------------------------------------------------

struct ListenerHandles {
    uint64_t remark  = 0;
    uint64_t shot    = 0;
    uint64_t match   = 0;
    uint64_t volley  = 0;
};

static ListenerHandles registerCallbacks(
    Torpedolib& lib, const std::string& side, EventLog& log)
{
    ListenerHandles h;

    h.remark = lib.onCaptainRemark(
        [&log](Torpedolib&, std::string_view captain, std::string_view phase,
               std::string_view message, int32_t turn) {
            char buf[512];
            std::snprintf(buf, sizeof(buf), "%.*s [%.*s] t%d: %.*s",
                          (int)captain.size(), captain.data(),
                          (int)phase.size(), phase.data(),
                          turn,
                          (int)message.size(), message.data());
            log.push(buf);
        });

    h.shot = lib.onShotResolved(
        [&log](Torpedolib&, std::string_view captain, int32_t turn,
               int32_t row, int32_t col, bool incoming, bool hit, bool sunk,
               std::string_view shipName, bool gameOver) {
            auto coord = coordLabel(row, col);
            const char* dir = incoming ? "defends" : "attacks";
            std::string outcome = "miss";
            if (hit)  outcome = "hit";
            if (sunk) outcome = std::string("sunk ") + std::string(shipName);
            if (gameOver) outcome += " and ended the duel";

            char buf[512];
            std::snprintf(buf, sizeof(buf), "%.*s %s %s on turn %d: %s",
                          (int)captain.size(), captain.data(),
                          dir, coord.c_str(), turn, outcome.c_str());
            log.push(buf);
        });

    h.match = lib.onMatchEnded(
        [&log](Torpedolib&, std::string_view captain, std::string_view outcome,
               std::string_view message, int32_t turn) {
            char buf[512];
            std::snprintf(buf, sizeof(buf), "%.*s %.*s on turn %d: %.*s",
                          (int)captain.size(), captain.data(),
                          (int)outcome.size(), outcome.data(),
                          turn,
                          (int)message.size(), message.data());
            log.push(buf);
        });

    h.volley = lib.onVolleyEvent(
        [&log](Torpedolib&, std::string_view captain, int32_t exchangeId,
               std::string_view stage, int32_t row, int32_t col,
               std::string_view reasoning, bool hit, bool sunk,
               std::string_view shipName, bool gameOver, std::string_view message) {
            auto coord = coordLabel(row, col);

            std::string detail;
            detail.reserve(256);
            detail += captain;
            detail += ' ';
            detail += stage;
            detail += " #";
            detail += std::to_string(exchangeId);
            detail += ' ';
            detail += coord;

            if (stage == "fire" && !reasoning.empty()) {
                detail += " [";
                detail += reasoning;
                detail += ']';
            }
            if (stage == "reply") {
                if (sunk) {
                    detail += " => sunk ";
                    detail += shipName;
                } else if (hit) {
                    detail += " => hit";
                } else {
                    detail += " => miss";
                }
                if (gameOver) detail += " => duel over";
            }
            if (!message.empty()) {
                detail += ": ";
                detail += message;
            }
            log.push(std::move(detail));
        });

    log.push(side + " event listeners attached");
    return h;
}

static void unregisterCallbacks(Torpedolib& lib, const ListenerHandles& h) {
    if (h.remark) lib.offCaptainRemark(h.remark);
    if (h.shot)   lib.offShotResolved(h.shot);
    if (h.match)  lib.offMatchEnded(h.match);
    if (h.volley) lib.offVolleyEvent(h.volley);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(int argc, char* argv[]) {
    Config cfg = parseArgs(argc, argv);
    EventLog eventLog(24);

    // ── Create library instances ──
    Torpedolib red, blue;
    {
        auto r = red.createContext();
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Red createContext: %s\n", r.error().c_str()); return 1; }
    }
    {
        auto r = blue.createContext();
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Blue createContext: %s\n", r.error().c_str()); return 1; }
    }

    // ── Register event listeners ──
    auto redHandles  = registerCallbacks(red,  "Red Fleet",  eventLog);
    auto blueHandles = registerCallbacks(blue, "Blue Fleet", eventLog);

    // ── Initialize captains ──
    {
        auto r = red.initializeCaptainRequest("Red Fleet", cfg.boardSize, "hunt", cfg.seedRed, cfg.turnDelayMs());
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Red init: %s\n", r.error().c_str()); return 1; }
    }
    {
        auto r = blue.initializeCaptainRequest("Blue Fleet", cfg.boardSize, "hunt", cfg.seedBlue, cfg.turnDelayMs());
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Blue init: %s\n", r.error().c_str()); return 1; }
    }

    // ── Auto-place fleets ──
    {
        auto r = red.autoPlaceFleetRequest();
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Red place: %s\n", r.error().c_str()); return 1; }
        eventLog.push("Red placed " + std::to_string(r->shipCount) + " ships");
    }
    {
        auto r = blue.autoPlaceFleetRequest();
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Blue place: %s\n", r.error().c_str()); return 1; }
        eventLog.push("Blue placed " + std::to_string(r->shipCount) + " ships");
    }

    // ── Link opponents ──
    {
        auto r = red.linkOpponentRequest(blue.ctx());
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Red link: %s\n", r.error().c_str()); return 1; }
    }
    {
        auto r = blue.linkOpponentRequest(red.ctx());
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Blue link: %s\n", r.error().c_str()); return 1; }
    }
    eventLog.push("Linked contexts red=" + std::to_string(red.ctx()) +
                  " blue=" + std::to_string(blue.ctx()));

    // ── Start the duel ──
    auto& starter = cfg.starterIsRed ? red : blue;
    std::string starterName = cfg.starterIsRed ? "Red Fleet" : "Blue Fleet";
    {
        auto r = starter.startGameRequest();
        if (!r.ok()) { std::fprintf(stderr, "FATAL: Start: %s\n", r.error().c_str()); return 1; }
    }

    std::string banner = starterName + " opens the duel";

    // ── Set up raw terminal for non-blocking key input ──
    RawTerminal term;

    // ── Observer loop ──
    auto sleepMs = [](double seconds) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(seconds * 1000)));
    };

    int exitCode = 0;
    // Use try-equivalent: unregister before shutdown to prevent
    // use-after-free on callback function objects.
    auto cleanup = [&]() {
        // Restore terminal before any final output
        term.restore();
        unregisterCallbacks(red,  redHandles);
        unregisterCallbacks(blue, blueHandles);
    };

    for (;;) {
        // Check for quit key
        char key = term.keyPressed();
        if (key == 'q' || key == 'Q') {
            break;
        }

        auto redView  = red.getPublicBoardRequest();
        auto blueView = blue.getPublicBoardRequest();

        if (!redView.ok() || !blueView.ok()) {
            std::fprintf(stderr, "FATAL: getPublicBoard failed\n");
            exitCode = 1;
            break;
        }

        auto lastEntry = eventLog.last();
        if (!lastEntry.empty()) banner = lastEntry;

        drawScreen(*redView, *blueView, eventLog, banner, cfg);

        if (redView->gameOver || blueView->gameOver) {
            // Final render with winner announcement
            auto finalRed  = red.getPublicBoardRequest();
            auto finalBlue = blue.getPublicBoardRequest();
            if (finalRed.ok() && finalBlue.ok()) {
                std::string winner = "Unknown";
                if (finalRed->hasWon)  winner = "Red Fleet";
                if (finalBlue->hasWon) winner = "Blue Fleet";
                banner = winner + " wins the duel";
                drawScreen(*finalRed, *finalBlue, eventLog, banner, cfg);
            }
            sleepMs(cfg.endDelay());
            break;
        }

        sleepMs(cfg.refreshDelay());
    }

    // Critical: unregister callbacks BEFORE destructor calls shutdown()
    cleanup();

    return exitCode;
}
