package enrich

import (
	"os"
	"testing"

	"github.com/awvidianto/sentinel-precision/db"
)

func TestMain(m *testing.M) {
	db.SuffixTestDatabase("enrich")
	os.Exit(m.Run())
}
