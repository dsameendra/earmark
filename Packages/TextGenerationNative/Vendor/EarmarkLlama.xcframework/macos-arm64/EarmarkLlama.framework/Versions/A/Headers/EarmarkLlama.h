#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void * earmark_llama_load(const char * path, const char * architecture, uint64_t minimum_parameters, uint64_t maximum_parameters, int32_t threads, char ** error);
char * earmark_llama_generate(void * handle, const char * prompt, int32_t maximum_input_tokens, int32_t maximum_tokens, char ** error);
char * earmark_llama_chat_prompt(void * handle, const char * content, char ** error);
char * earmark_llama_tokens(void * handle, const char * prompt, char ** error);
void earmark_llama_unload(void * handle);
void earmark_llama_free_text(char * text);
#ifdef __cplusplus
}
#endif
