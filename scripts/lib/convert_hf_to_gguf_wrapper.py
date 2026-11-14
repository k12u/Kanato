# llama.cpp の convert_hf_to_gguf.py を、前処理（pre-tokenizer）を指定して実行するラッパー。
#
#   python convert_hf_to_gguf_wrapper.py <llama.cpp ソースディレクトリ> <convert_hf_to_gguf.py の引数...>
#
# 環境変数 KANATO_PRE_TOKENIZER が設定されていれば、トークナイザーのハッシュ判定を行わずにその値を使う。
# zenz（GPT2Tokenizer、文字単位 + バイト BPE）は既知ハッシュに無いため "gpt-2" を指定する。
import os
import runpy
import sys

src = sys.argv.pop(1)
sys.path.insert(0, src)

pre = os.environ.get("KANATO_PRE_TOKENIZER")
if pre:
    import conversion.base as base
    base.TextModel.get_vocab_base_pre = lambda self, tokenizer: pre

sys.argv[0] = os.path.join(src, "convert_hf_to_gguf.py")
runpy.run_path(sys.argv[0], run_name="__main__")
