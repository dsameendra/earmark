#include "earmark_nllb.h"
#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
struct Model {
    std::unique_ptr<ctranslate2::Translator> translator;
    sentencepiece::SentencePieceProcessor tokenizer;
    sentencepiece::SentencePieceProcessor target_tokenizer;
    int profile = 1;
};
char *copy(const std::string &value) {
    auto *result = static_cast<char *>(std::malloc(value.size() + 1));
    if (!result) throw std::bad_alloc();
    std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}
void failure(char **error, const std::exception &exception) noexcept {
    if (error) *error = ::strdup(exception.what());
}
void check(const sentencepiece::util::Status &status) {
    if (!status.ok()) throw std::runtime_error(status.ToString());
}
std::vector<std::string> encode(Model *model, const char *text) {
    if (!model || !text) throw std::invalid_argument("Missing model or text");
    std::vector<std::string> pieces;
    check(model->tokenizer.Encode(text, &pieces));
    return pieces;
}
}
extern "C" void *earmark_translation_load(const char *folder, int profile, int threads, char **error) {
    if (error) *error = nullptr;
    try {
        if (!folder) throw std::invalid_argument("Missing model folder");
        if (profile < 1 || profile > 3) throw std::invalid_argument("Unsupported translation profile");
        auto model = std::make_unique<Model>();
        model->profile = profile;
        const char *source_file = profile == 1 ? "sentencepiece.bpe.model" : (profile == 2 ? "spiece.model" : "source.spm");
        check(model->tokenizer.Load(std::string(folder) + "/" + source_file));
        if (profile == 3) check(model->target_tokenizer.Load(std::string(folder) + "/target.spm"));
        ctranslate2::ReplicaPoolConfig config;
        config.num_threads_per_replica = threads > 0 ? threads : 4;
        model->translator = std::make_unique<ctranslate2::Translator>(folder, ctranslate2::Device::CPU, ctranslate2::ComputeType::INT8, std::vector<int>{0}, false, config);
        return model.release();
    } catch (const std::exception &exception) { failure(error, exception); return nullptr; }
}
extern "C" void *earmark_nllb_load(const char *folder, int threads, char **error) {
    return earmark_translation_load(folder, 1, threads, error);
}
extern "C" void earmark_nllb_unload(void *model) { delete static_cast<Model *>(model); }
extern "C" char *earmark_nllb_translate(void *handle, const char *text, const char *source, const char *target, char **error) {
    if (error) *error = nullptr;
    try {
        auto *model = static_cast<Model *>(handle);
        if (!source || !target) throw std::invalid_argument("Missing language tags");
        if (!model || !text) throw std::invalid_argument("Missing model or text");
        std::vector<std::string> pieces;
        std::vector<std::string> prefix;
        if (model->profile == 2) {
            const std::string language_token = "<2" + std::string(target) + ">";
            if (model->tokenizer.PieceToId(language_token) == model->tokenizer.unk_id())
                throw std::invalid_argument("Unsupported MADLAD target language");
            const std::string prompted = language_token + " " + text;
            pieces = encode(model, prompted.c_str());
            if (pieces.size() > 1023) throw std::invalid_argument("Text exceeds the MADLAD input limit; split it into shorter segments");
            pieces.push_back("</s>");
        } else {
            pieces = encode(model, text);
            if (pieces.size() > (model->profile == 1 ? 500u : 511u))
                throw std::invalid_argument("Text exceeds this model's input limit; split it into shorter segments");
            if (model->profile == 1) {
                pieces.insert(pieces.begin(), source);
                prefix.push_back(target);
            }
            // MarianTokenizer appends EOS too. The converted model's
            // add_source_eos=false means the caller must supply it.
            pieces.push_back("</s>");
        }
        ctranslate2::TranslationOptions options;
        options.beam_size = 4;
        options.max_decoding_length = 256;
        auto results = model->translator->translate_batch({pieces}, {prefix}, options);
        if (results.empty() || results[0].hypotheses.empty()) throw std::runtime_error("No translation returned");
        auto tokens = results[0].hypotheses[0];
        if (tokens.size() >= options.max_decoding_length)
            throw std::runtime_error("Translation reached the decoding limit; split the source into shorter segments");
        if (!prefix.empty() && !tokens.empty() && tokens.front() == target) tokens.erase(tokens.begin());
        std::string translated;
        if (model->profile == 3) check(model->target_tokenizer.Decode(tokens, &translated));
        else check(model->tokenizer.Decode(tokens, &translated));
        return copy(translated);
    } catch (const std::exception &exception) { failure(error, exception); return nullptr; }
}
extern "C" void *earmark_nllb_encode(void *handle, const char *text, char **error) {
    if (error) *error = nullptr;
    try { return new std::vector<std::string>(encode(static_cast<Model *>(handle), text)); }
    catch (const std::exception &exception) { failure(error, exception); return nullptr; }
}
extern "C" size_t earmark_nllb_token_count(const void *tokens) {
    return tokens ? static_cast<const std::vector<std::string> *>(tokens)->size() : 0;
}
extern "C" const char *earmark_nllb_token(const void *tokens, size_t index) {
    if (!tokens) return nullptr;
    const auto &pieces = *static_cast<const std::vector<std::string> *>(tokens);
    return index < pieces.size() ? pieces[index].c_str() : nullptr;
}
extern "C" void earmark_nllb_free_tokens(void *tokens) { delete static_cast<std::vector<std::string> *>(tokens); }
extern "C" void earmark_nllb_free_text(char *text) { std::free(text); }
