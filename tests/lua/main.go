package main

import (
	"encoding/json"
	"fmt"
	"os"

	lua "github.com/yuin/gopher-lua"
	luajson "layeh.com/gopher-json"
)

// Mirrors how Argo CD executes a resource health Lua script:
// the object is injected as the global `obj`, and the script returns `hs`.
func run(script string, objJSON string) (string, string, error) {
	L := lua.NewState()
	defer L.Close()
	luajson.Preload(L)

	var obj interface{}
	if err := json.Unmarshal([]byte(objJSON), &obj); err != nil {
		return "", "", err
	}
	lv := decode(L, obj)
	L.SetGlobal("obj", lv)

	if err := L.DoString(script); err != nil {
		return "", "", err
	}
	ret := L.Get(-1)
	tbl, ok := ret.(*lua.LTable)
	if !ok {
		return "", "", fmt.Errorf("script did not return a table, got %s", ret.Type())
	}
	status := tbl.RawGetString("status").String()
	message := tbl.RawGetString("message").String()
	return status, message, nil
}

func decode(L *lua.LState, v interface{}) lua.LValue {
	switch x := v.(type) {
	case nil:
		return lua.LNil
	case bool:
		return lua.LBool(x)
	case float64:
		return lua.LNumber(x)
	case string:
		return lua.LString(x)
	case []interface{}:
		t := L.NewTable()
		for _, item := range x {
			t.Append(decode(L, item))
		}
		return t
	case map[string]interface{}:
		t := L.NewTable()
		for k, item := range x {
			t.RawSetString(k, decode(L, item))
		}
		return t
	}
	return lua.LNil
}

func main() {
	script, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	objJSON, err := os.ReadFile(os.Args[2])
	if err != nil {
		panic(err)
	}
	status, msg, err := run(string(script), string(objJSON))
	if err != nil {
		fmt.Printf("ERROR\t%v\n", err)
		os.Exit(1)
	}
	fmt.Printf("%s\t%s\n", status, msg)
}
