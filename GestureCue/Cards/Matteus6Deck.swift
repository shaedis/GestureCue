import Foundation

extension Presentation {
    /// Sample text-only deck: the Gospel of Matthew, chapter 6, verses 1–34
    /// (Swedish). One card per verse; no pictures, no detail lines.
    static func matteus6() -> Presentation {
        Presentation(name: "Matteus 6", cards: PresentationCard.matteus6)
    }

    static let matteus6Name = "Matteus 6"
}

extension PresentationCard {
    /// Matthew 6:1–34 as (title, verse) pairs, transcribed from the
    /// `Matteus_6_Evangelietext_Zoom_34_verser.pdf` sample.
    static let matteus6: [PresentationCard] = [
        ("Matteus 6:1", "Var noga med att inte utföra era fromma gärningar i människornas åsyn, för att de skall lägga märke till er. Annars har ni ingen lön att vänta hos er fader i himlen."),
        ("Matteus 6:2", "När du ger allmosor, låt då inte stöta i basun för dig, som hycklarna gör i synagogorna och på gatorna för att människorna skall prisa dem. Sannerligen, de har redan fått ut sin lön."),
        ("Matteus 6:3", "Nej, när du ger allmosor, låt då inte vänstra handen veta vad den högra gör."),
        ("Matteus 6:4", "Ge din allmosa i det fördolda. Då skall din fader, som ser i det fördolda, belöna dig."),
        ("Matteus 6:5", "När ni ber skall ni inte göra som hycklarna. De älskar att stå och be i synagogorna och i gathörnen för att människorna skall se dem. Sannerligen, de har redan fått ut sin lön."),
        ("Matteus 6:6", "Nej, när du ber, gå då in i din kammare, stäng dörren och be sedan till din fader som är i det fördolda. Då skall din fader, som ser i det fördolda, belöna dig."),
        ("Matteus 6:7", "Och när ni ber skall ni inte rabbla tomma ord som hedningarna; de tror att de skall bli bönhörda för de många ordens skull."),
        ("Matteus 6:8", "Gör inte som de, ty er fader vet vad ni behöver redan innan ni har bett honom om det."),
        ("Matteus 6:9", "Så skall ni be: Vår fader, du som är i himlen. Låt ditt namn bli helgat."),
        ("Matteus 6:10", "Låt ditt rike komma. Låt din vilja ske, på jorden så som i himlen."),
        ("Matteus 6:11", "Ge oss i dag vårt bröd för dagen som kommer."),
        ("Matteus 6:12", "Och förlåt oss våra skulder, liksom vi har förlåtit dem som står i skuld till oss."),
        ("Matteus 6:13", "Och utsätt oss inte för prövning, utan rädda oss från det onda."),
        ("Matteus 6:14", "Ty om ni förlåter människorna deras överträdelser skall er himmelske fader också förlåta er."),
        ("Matteus 6:15", "Men om ni inte förlåter människorna skall inte heller er fader förlåta er era överträdelser."),
        ("Matteus 6:16", "När ni fastar, se då inte dystra ut som hycklarna, som vanställer sitt utseende för att människorna skall se att de fastar. Sannerligen, de har redan fått ut sin lön."),
        ("Matteus 6:17", "Nej, när du fastar, smörj in ditt hår och tvätta ditt ansikte,"),
        ("Matteus 6:18", "så att inte människorna ser att du fastar, utan bara din fader i det fördolda. Då skall din fader, som ser i det fördolda, belöna dig."),
        ("Matteus 6:19", "Samla inte skatter här på jorden, där mal och mask förstör och tjuvar bryter sig in och stjäl."),
        ("Matteus 6:20", "Samla skatter i himlen, där varken mal eller mask förstör och inga tjuvar bryter sig in och stjäl."),
        ("Matteus 6:21", "Ty där din skatt är, där kommer också ditt hjärta att vara."),
        ("Matteus 6:22", "Kroppens lampa är ögat. Om ditt öga är ogrumlat får hela din kropp ljus,"),
        ("Matteus 6:23", "men om ditt öga är fördärvat blir det mörkt i hela din kropp. Om nu ljuset inom dig är mörker, hur djupt blir då inte mörkret."),
        ("Matteus 6:24", "Ingen kan tjäna två herrar. Antingen kommer han att hata den ene och älska den andre eller att hålla fast vid den ene och inte bry sig om den andre. Ni kan inte tjäna både Gud och mammon."),
        ("Matteus 6:25", "Därför säger jag er: bekymra er inte för mat och dryck att leva av eller för kläder att sätta på kroppen. Är inte livet mer än födan och kroppen mer än kläderna?"),
        ("Matteus 6:26", "Se på himlens fåglar, de sår inte, skördar inte och samlar inte i lador, men er himmelske fader föder dem. Är inte ni värda mycket mer än de?"),
        ("Matteus 6:27", "Vem av er kan med sina bekymmer lägga en enda aln till sin livslängd?"),
        ("Matteus 6:28", "Och varför bekymrar ni er för kläder? Se på ängens liljor, hur de växer. De arbetar inte och spinner inte."),
        ("Matteus 6:29", "Men jag säger er: inte ens Salomo i all sin prakt var klädd som en av dem."),
        ("Matteus 6:30", "Om nu Gud ger sådana kläder åt gräset på ängen, som i dag finns till och i morgon stoppas i ugnen, skall han då inte ha kläder åt er, ni trossvaga?"),
        ("Matteus 6:31", "Gör er därför inga bekymmer, fråga inte: Vad skall vi äta? Vad skall vi dricka? Vad skall vi ta på oss?"),
        ("Matteus 6:32", "Allt sådant jagar hedningarna efter. Men er himmelske fader vet att ni behöver allt detta."),
        ("Matteus 6:33", "Sök först hans rike och hans rättfärdighet, så skall ni få allt det andra också."),
        ("Matteus 6:34", "Gör er därför inga bekymmer för morgondagen. Den får själv bära sina bekymmer. Var dag har nog av sin egen plåga."),
    ].map { PresentationCard(title: $0, message: $1) }
}
