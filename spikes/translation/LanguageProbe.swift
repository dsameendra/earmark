import Foundation
import Translation
let av = LanguageAvailability()
let langs = await av.supportedLanguages
let ids = langs.map { $0.minimalIdentifier }.sorted()
print("supportedLanguages (\(ids.count)):", ids.joined(separator: " "))
print("contains si:", ids.contains("si"))
let en = Locale.Language(identifier: "en")
for l in ids where l != "en" {
  let s = await av.status(from: Locale.Language(identifier: l), to: en)
  print(l, "->en", s)
}
let si = Locale.Language(identifier: "si")
print("si->en", await av.status(from: si, to: en))
print("en->si", await av.status(from: en, to: si))
