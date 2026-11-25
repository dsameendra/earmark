#ifndef EARMARK_NLLB_H
#define EARMARK_NLLB_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* All returned text is UTF-8 and owned by the caller via earmark_nllb_free_text. */
/* Profiles: 1 = NLLB, 2 = MADLAD/T5, 3 = directional Marian/OPUS. */
void *earmark_translation_load(const char *folder, int profile, int threads, char **error);
void *earmark_nllb_load(const char *folder, int threads, char **error);
void earmark_nllb_unload(void *model);
char *earmark_nllb_translate(void *model, const char *text, const char *source, const char *target, char **error);
void *earmark_nllb_encode(void *model, const char *text, char **error);
size_t earmark_nllb_token_count(const void *tokens);
const char *earmark_nllb_token(const void *tokens, size_t index);
void earmark_nllb_free_tokens(void *tokens);
void earmark_nllb_free_text(char *text);
#ifdef __cplusplus
}
#endif
#endif
