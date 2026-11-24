#include "EarmarkLlama.h"
#include "llama.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int context_tokens = 4096;
constexpr int batch_tokens = 512;
struct Runtime {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    llama_sampler * sampler = nullptr;
    llama_batch_ext * batch = nullptr;
    ~Runtime() {
        if (batch) llama_batch_ext_free(batch);
        if (sampler) llama_sampler_free(sampler);
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }
};

char * copy(const std::string & text) {
    auto result = static_cast<char *>(std::malloc(text.size() + 1));
    if (!result) throw std::bad_alloc();
    std::memcpy(result, text.c_str(), text.size() + 1);
    return result;
}

void fail(char ** error, const char * message) noexcept {
    if (error) *error = ::strdup(message);
}

void quiet_log(enum ggml_log_level, const char *, void *) {}

void decode(Runtime & runtime, const llama_token * tokens, int count, int position) {
    llama_batch_ext_clear(runtime.batch);
    for (int i = 0; i < count; ++i) {
        const int index = llama_batch_ext_add_token(runtime.batch, 0, tokens[i]);
        const llama_pos token_position = position + i;
        if (index < 0 || !llama_batch_ext_set_pos(runtime.batch, index, &token_position)) {
            throw std::runtime_error("Could not construct a bounded generation batch.");
        }
    }
    if (!llama_batch_ext_set_output_logits(runtime.batch, count - 1, true) ||
        llama_process(runtime.context, LLAMA_PROCESS_TYPE_DECODE, runtime.batch) != 0) {
        throw std::runtime_error("The native text model could not decode this request.");
    }
}
}

extern "C" void * earmark_llama_load(const char * path, const char * architecture, uint64_t minimum_parameters, uint64_t maximum_parameters, int32_t threads, char ** error) {
    try {
        if (!path || !architecture || threads < 1 || threads > 64) throw std::runtime_error("Invalid native text model configuration.");
        static std::once_flag initialized;
        std::call_once(initialized, [] { llama_log_set(quiet_log, nullptr); llama_backend_init(); });
        auto runtime = std::make_unique<Runtime>();
        auto model_options = llama_model_default_params();
        model_options.n_gpu_layers = 99;
        runtime->model = llama_model_load_from_file(path, model_options);
        if (!runtime->model) throw std::runtime_error("Could not load the installed GGUF text model.");
        char actual[128] = {};
        const int size = llama_model_meta_val_str(runtime->model, "general.architecture", actual, sizeof(actual));
        if (size <= 0 || size >= static_cast<int>(sizeof(actual)) || std::string(actual) != architecture || llama_model_has_encoder(runtime->model)) {
            throw std::runtime_error("The GGUF architecture does not match the selected translation profile.");
        }
        const uint64_t parameters = llama_model_n_params(runtime->model);
        if (parameters < minimum_parameters || parameters > maximum_parameters) throw std::runtime_error("The model size does not match the selected translation variant.");
        auto options = llama_context_default_params();
        options.n_ctx = context_tokens;
        options.n_batch = batch_tokens;
        options.n_ubatch = batch_tokens;
        options.n_threads = threads;
        options.n_threads_batch = threads;
        options.no_perf = true;
        runtime->context = llama_init_from_model(runtime->model, options);
        if (!runtime->context) throw std::runtime_error("Could not allocate the native translation context.");
        runtime->sampler = llama_sampler_init_greedy();
        runtime->batch = llama_batch_ext_init(runtime->context);
        if (!runtime->sampler || !runtime->batch) throw std::runtime_error("Could not allocate native generation state.");
        return runtime.release();
    } catch (const std::exception & exception) { fail(error, exception.what()); }
    catch (...) { fail(error, "Unknown native text model load failure."); }
    return nullptr;
}

extern "C" char * earmark_llama_chat_prompt(void * handle, const char * content, char ** error) {
    try {
        if (!handle || !content || std::strlen(content) > 64 * 1024) throw std::runtime_error("Invalid translation prompt size.");
        auto & runtime = *static_cast<Runtime *>(handle);
        const char * format = llama_model_chat_template(runtime.model, nullptr);
        if (!format) throw std::runtime_error("The model has no supported chat template.");
        const llama_chat_message message = {"user", content};
        std::vector<char> buffer(128 * 1024);
        const int count = llama_chat_apply_template(format, &message, 1, true, buffer.data(), static_cast<int>(buffer.size()));
        if (count <= 0 || count >= static_cast<int>(buffer.size())) throw std::runtime_error("Unsupported or oversized model chat template.");
        return copy(std::string(buffer.data(), count));
    } catch (const std::exception & exception) { fail(error, exception.what()); }
    catch (...) { fail(error, "Unknown native chat template failure."); }
    return nullptr;
}

extern "C" char * earmark_llama_generate(void * handle, const char * prompt, int32_t maximum_input_tokens, int32_t maximum_tokens, char ** error) {
    try {
        if (!handle || !prompt || std::strlen(prompt) > 128 * 1024 || maximum_tokens < 1 || maximum_tokens > 1024 || maximum_input_tokens < 1 || maximum_input_tokens > context_tokens) {
            throw std::runtime_error("Invalid native generation limits.");
        }
        auto & runtime = *static_cast<Runtime *>(handle);
        const auto * vocabulary = llama_model_get_vocab(runtime.model);
        const int length = static_cast<int>(std::strlen(prompt));
        const int required = -llama_tokenize(vocabulary, prompt, length, nullptr, 0, true, true);
        if (required <= 0 || required > maximum_input_tokens || required + maximum_tokens > context_tokens) throw std::runtime_error("Text exceeds the model's bounded context. Use shorter segments.");
        std::vector<llama_token> tokens(required);
        const int count = llama_tokenize(vocabulary, prompt, length, tokens.data(), required, true, true);
        if (count != required) throw std::runtime_error("Could not tokenize the native translation prompt.");
        llama_memory_clear(llama_get_memory(runtime.context), true);
        llama_sampler_reset(runtime.sampler);
        for (int offset = 0; offset < count; offset += batch_tokens) {
            decode(runtime, tokens.data() + offset, std::min(batch_tokens, count - offset), offset);
        }
        std::string output;
        for (int i = 0; i < maximum_tokens; ++i) {
            const llama_token token = llama_sampler_sample(runtime.sampler, runtime.context, -1);
            if (llama_vocab_is_eog(vocabulary, token)) {
                if (output.find('\0') != std::string::npos) throw std::runtime_error("The model returned invalid null-containing text.");
                return copy(output);
            }
            std::vector<char> piece(256);
            int size = llama_token_to_piece(vocabulary, token, piece.data(), static_cast<int>(piece.size()), 0, false);
            if (size < 0) {
                if (size < -65536) throw std::runtime_error("Native token exceeded output limits.");
                piece.resize(-size);
                size = llama_token_to_piece(vocabulary, token, piece.data(), static_cast<int>(piece.size()), 0, false);
            }
            if (size < 0 || size > static_cast<int>(piece.size()) || output.size() + size > 1024 * 1024) {
                throw std::runtime_error("Native text output exceeded its limits.");
            }
            output.append(piece.data(), size);
            decode(runtime, &token, 1, count + i);
        }
        throw std::runtime_error("Translation reached its output limit before completion. Use shorter segments.");
    } catch (const std::exception & exception) { fail(error, exception.what()); }
    catch (...) { fail(error, "Unknown native generation failure."); }
    return nullptr;
}

extern "C" char * earmark_llama_tokens(void * handle, const char * prompt, char ** error) {
    try {
        if (!handle || !prompt || std::strlen(prompt) > 128 * 1024) throw std::runtime_error("Invalid tokenization input size.");
        auto & runtime = *static_cast<Runtime *>(handle);
        const auto * vocabulary = llama_model_get_vocab(runtime.model);
        const int length = static_cast<int>(std::strlen(prompt));
        const int required = -llama_tokenize(vocabulary, prompt, length, nullptr, 0, true, true);
        if (required <= 0 || required > context_tokens) throw std::runtime_error("Tokenization input exceeds the context limit.");
        std::vector<llama_token> tokens(required);
        if (llama_tokenize(vocabulary, prompt, length, tokens.data(), required, true, true) != required) throw std::runtime_error("Native tokenization failed.");
        std::string result = "[";
        for (int i = 0; i < required; ++i) {
            if (i) result += ",";
            result += std::to_string(tokens[i]);
        }
        return copy(result + "]");
    } catch (const std::exception & exception) { fail(error, exception.what()); }
    catch (...) { fail(error, "Unknown native tokenization failure."); }
    return nullptr;
}

extern "C" void earmark_llama_unload(void * handle) { delete static_cast<Runtime *>(handle); }
extern "C" void earmark_llama_free_text(char * text) { std::free(text); }
