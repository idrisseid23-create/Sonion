// Minimal Luau runner for offline tests: runs a script file, exposes __loadfile(path) for a Lua-side require.
#include "lua.h"
#include "lualib.h"
#include "luacode.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <fstream>
#include <sstream>

static bool readFile(const char* path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::stringstream ss; ss << f.rdbuf(); out = ss.str(); return true;
}

static int loadChunk(lua_State* L, const std::string& src, const char* chunkname) {
    size_t bcSize = 0;
    lua_CompileOptions opts = {};
    opts.optimizationLevel = 1;
    opts.debugLevel = 2;
    char* bc = luau_compile(src.data(), src.size(), &opts, &bcSize);
    int r = luau_load(L, chunkname, bc, bcSize, 0);
    free(bc);
    return r;
}

static int l_loadfile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string src;
    if (!readFile(path, src)) { lua_pushnil(L); lua_pushfstring(L, "cannot read %s", path); return 2; }
    std::string name = std::string("@") + path;
    if (loadChunk(L, src, name.c_str()) != 0) { lua_pushnil(L); lua_insert(L, -2); return 2; }
    return 1;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: luaurun file.luau [args]\n"); return 2; }
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    lua_pushcfunction(L, l_loadfile, "__loadfile");
    lua_setglobal(L, "__loadfile");
    lua_newtable(L);
    for (int i = 2; i < argc; i++) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - 1); }
    lua_setglobal(L, "arg");
    std::string src;
    if (!readFile(argv[1], src)) { fprintf(stderr, "cannot read %s\n", argv[1]); return 2; }
    std::string name = std::string("@") + argv[1];
    if (loadChunk(L, src, name.c_str()) != 0) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
    lua_getglobal(L, "debug"); lua_getfield(L, -1, "traceback"); lua_remove(L, -2);
    lua_insert(L, -2);
    if (lua_pcall(L, 0, 0, -2) != 0) { fprintf(stderr, "ERROR: %s\n", lua_tostring(L, -1)); return 1; }
    return 0;
}
