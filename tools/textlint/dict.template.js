// The proper-noun tripwire: what the morpheme-match rule reports.
//
// This file is yours: install.sh creates it when missing and never replaces
// it. It holds no Japanese-language machinery -- the analyser (kuromoji) and
// its dictionary come with the rule package. What is here is one policy
// statement: which morphemes are worth a report.
//
// The pattern below matches any token the analyser tags as a proper noun, so
// every name reaching the documents has to be declared in allow.yml first --
// the vocabulary contract of check-private.py, applied to Japanese prose,
// where a denylist cannot catch the name nobody knew about.
//
// Known limits, both measured (2026-08-16): a title built from ordinary
// words (『架空の蔵書目録』) is not tagged as a proper noun and is not
// caught here; and the dictionary is IPAdic, which tags some ordinary words
// as proper nouns -- those go in allow.yml as they turn up.
module.exports = [
  {
    tokens: [{ pos: "名詞", pos_detail_1: "固有名詞" }],
    message: "固有名詞です。allow.yml で宣言されているか確認してください",
  },
];
