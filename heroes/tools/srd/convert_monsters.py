"""Собирает data/monsters.json для игры из SRD 5.1 (CC-BY-4.0, Wizards of the Coast).
Запуск: python3 tools/srd/convert_monsters.py  (из папки heroes)."""
import json, re, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from ru_monsters import RU, TYPE, DT, ATK, AOE

SRC = os.path.join(os.path.dirname(__file__), "srd_monsters_en.json")
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "data", "monsters.json")

AB = {"STR": "СИЛ", "DEX": "ЛОВ", "CON": "ТЕЛ", "INT": "ИНТ", "WIS": "МДР", "CHA": "ХАР",
	"Strength": "СИЛ", "Dexterity": "ЛОВ", "Constitution": "ТЕЛ", "Intelligence": "ИНТ", "Wisdom": "МДР", "Charisma": "ХАР"}
XP = {0: 10, 0.125: 25, 0.25: 50, 0.5: 100, 1: 200, 2: 450, 3: 700, 4: 1100, 5: 1800, 6: 2300, 7: 2900, 8: 3900, 9: 5000, 10: 5900,
	11: 7200, 12: 8400, 13: 10000, 14: 11500, 15: 13000, 16: 15000, 17: 18000, 18: 20000, 19: 22000, 20: 25000, 21: 33000, 22: 41000,
	23: 50000, 24: 62000, 30: 155000}
COND = {"poisoned": "poisoned", "frightened": "frightened", "prone": "prone", "stunned": "stunned", "paralyzed": "held",
	"restrained": "prone", "blinded": "blinded", "incapacitated": "stunned", "petrified": "held", "charmed": "frightened"}
SPELL_MAP = {"fire bolt": "fire_bolt", "ray of frost": "ray_of_frost", "sacred flame": "sacred_flame", "magic missile": "magic_missile",
	"burning hands": "burning_hands", "thunderwave": "thunderwave", "guiding bolt": "guiding_bolt", "cure wounds": "cure_wounds",
	"hold person": "hold_person", "scorching ray": "scorching_ray", "shatter": "shatter", "fireball": "fireball", "ice storm": "ice_storm",
	"cone of cold": "cone_of_cold", "flame strike": "flame_strike", "blight": "blight", "shocking grasp": "shocking_grasp",
	"lightning bolt": "lightning_bolt", "inflict wounds": "inflict_wounds", "chill touch": "chill_touch", "eldritch blast": "eldritch_blast",
	"vicious mockery": "vicious_mockery", "spiritual weapon": "spiritual_weapon", "mass cure wounds": "mass_cure_wounds",
	"finger of death": "finger_of_death", "harm": "harm", "chain lightning": "chain_lightning", "hellish rebuke": "hellish_rebuke"}
NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7}


def slug(n):
	return re.sub(r"[^a-z0-9]+", "_", n.lower()).strip("_")


def mod(v):
	return (int(v) - 10) // 2


def dt_list(arr):
	out = []
	for s in arr:
		for k, v in DT.items():
			if k in s.lower() and v not in out:
				out.append(v)
	return out


def dmg_parts(a):
	parts = []
	for d in a.get("damage", []) or []:
		if not isinstance(d, dict):
			continue
		if "damage_dice" in d:
			t = d.get("damage_type", {}).get("name", "").lower() if isinstance(d.get("damage_type"), dict) else str(d.get("damage_type", "")).lower()
			parts.append((d["damage_dice"], int(d.get("damage_bonus", 0) or 0), DT.get(t, "дробящий")))
		elif "dice" in d:
			parts.append((d["dice"], int(d.get("bonus", 0) or 0), DT.get(str(d.get("type", "")).lower(), "дробящий")))
		elif "from" in d or "choose" in d:
			continue
	return parts


def expr(dice, bonus):
	dice = str(dice).replace(" ", "")
	m = re.match(r"^(\d+)d(\d+)(?:\+(\d+))?$", dice)
	if not m:
		m2 = re.match(r"^(\d+)$", dice)
		if m2:
			return "1d1+%d" % (int(m2.group(1)) - 1 + bonus) if int(m2.group(1)) + bonus > 1 else "1d1"
		return "1d6"
	b = bonus + int(m.group(3) or 0)
	return "%sd%s%s" % (m.group(1), m.group(2), ("+%d" % b) if b > 0 else (("-%d" % -b) if b < 0 else ""))


def on_hit_save(desc):
	m = re.search(r"DC (\d+) (Strength|Dexterity|Constitution|Intelligence|Wisdom|Charisma) saving throw", desc)
	if not m:
		return None
	sv = {"a": AB[m.group(2)], "dc": int(m.group(1))}
	low = desc.lower()
	for k, v in COND.items():
		if ("be " + k in low) or ("is " + k in low) or ("become " + k in low) or ("knocked prone" in low and k == "prone"):
			sv["c"] = "stunned" if v == "held" else v
			break
	m2 = re.search(r"taking \d+ \((\d+d\d+(?: ?\+ ?\d+)?)\) (\w+) damage on a failed save", desc)
	if m2:
		sv["dmg"] = m2.group(1).replace(" ", "")
		sv["dt"] = DT.get(m2.group(2), "яд")
	return sv


def multi_count(desc, names):
	low = desc.lower()
	m = re.search(r"makes (one|two|three|four|five|six|seven) (?:\w+ )?attacks", low)
	if m:
		return NUM[m.group(1)]
	tot = 0
	for w, n in NUM.items():
		tot += len(re.findall(r"\b%s\b (?:with|of)" % w, low)) * n
	return max(1, min(tot, 6)) if tot else 2


def ru_atk(n):
	base = re.sub(r"\s*\(.*\)\.?", "", n).strip()
	return ATK.get(base, base)


def convert(x):
	en = x["name"]
	r = {"name": RU.get(en, en), "en": en, "type": TYPE.get(x["type"], x["type"]), "size": x["size"],
		"ac": int(x["armor_class"]) if not isinstance(x["armor_class"], list) else int(x["armor_class"][0]["value"]),
		"hp": int(x["hit_points"]), "cr": x["challenge_rating"], "xp": XP.get(x["challenge_rating"], 10)}
	ab = {"СИЛ": mod(x["strength"]), "ЛОВ": mod(x["dexterity"]), "ТЕЛ": mod(x["constitution"]), "ИНТ": mod(x["intelligence"]),
		"МДР": mod(x["wisdom"]), "ХАР": mod(x["charisma"])}
	r["ab"] = ab
	r["dex"] = ab["ЛОВ"]
	sv = {}
	for p in x.get("proficiencies", []):
		m = re.match(r"Saving Throw: (\w+)", p["name"])
		if m:
			sv[AB[m.group(1)]] = int(p["value"])
	if sv:
		r["sv"] = sv
	for key, src in [("vuln", "damage_vulnerabilities"), ("res", "damage_resistances"), ("imm", "damage_immunities")]:
		plain = [t for t in x.get(src, []) if "nonmagical" not in t.lower()]
		nm = [t for t in x.get(src, []) if "nonmagical" in t.lower()]
		l = dt_list(plain)
		if l:
			r[key] = l
		if nm:
			r["resnm"] = sorted(set(r.get("resnm", []) + dt_list(nm)))
	ci = []
	for c in x.get("condition_immunities", []):
		cn = c["name"].lower() if isinstance(c, dict) else str(c).lower()
		if COND.get(cn) and COND[cn] not in ci:
			ci.append(COND[cn])
	if ci:
		r["cimm"] = ci
	if x["type"] == "undead":
		r["undead"] = True
	if x["type"] == "beast" or "swarm" in x["type"]:
		r["beast"] = True
	if x["type"] != "humanoid":
		r["nonhuman"] = True
	if x["size"] in ["Large", "Huge", "Gargantuan"]:
		r["big"] = True
	if "fly" in x.get("speed", {}):
		r["fly"] = True
	atks = []
	aoe = []
	multi_desc = ""
	for a in x.get("actions", []) or []:
		nm = a["name"]
		desc = a.get("desc", "")
		if nm == "Multiattack":
			multi_desc = desc
			continue
		if "Form Only" in nm and "Humanoid" not in nm and "Hybrid" not in nm and "Fiend" not in nm and "Vampire Form" not in nm:
			continue
		if "attack_bonus" in a and dmg_parts(a):
			parts = dmg_parts(a)
			at = {"n": ru_atk(nm), "hit": int(a["attack_bonus"]), "dmg": expr(parts[0][0], parts[0][1]), "dt": parts[0][2]}
			if len(parts) > 1:
				at["x"] = expr(parts[1][0], parts[1][1])
				at["xdt"] = parts[1][2]
			if "Ranged" in desc and "Melee or Ranged" not in desc:
				at["r"] = True
			s = on_hit_save(desc)
			if s:
				at["sv"] = s
			if "Life Drain" in nm or "Blood Drain" in nm or "Draining" in nm:
				at["drain"] = True
			atks.append(at)
			continue
		rech = 0
		mr = re.search(r"Recharge (\d)", nm)
		if mr:
			rech = int(mr.group(1))
		base = re.sub(r"\s*\(.*\)", "", nm).strip()
		if base == "Frightful Presence" or base in ["Horrifying Visage", "Dreadful Glare", "Moan", "Horror Nimbus", "Scare"]:
			m = re.search(r"DC (\d+)", desc)
			if m:
				r["fear"] = int(m.group(1))
			continue
		if base == "Healing Touch":
			r["healer"] = True
			continue
		dc = a.get("dc")
		if dc and dc.get("dc_value"):
			d = {"n": AOE.get(base, base), "a": AB.get(dc["dc_type"]["name"], "ЛОВ"), "dc": int(dc["dc_value"]), "rech": rech}
			parts = dmg_parts(a)
			if not parts and "Breath Weapons" in nm:
				m = re.search(r"\((\d+d\d+)\) (\w+) damage", desc)
				if m:
					parts = [(m.group(1), 0, DT.get(m.group(2), "огонь"))]
			if parts:
				d["dmg"] = expr(parts[0][0], parts[0][1])
				d["dt"] = parts[0][2]
				d["half"] = "half as much" in desc
			low = desc.lower()
			for k, v in COND.items():
				if ("be " + k in low) or ("become " + k in low) or ("is " + k in low) or ("knocked prone" in low and k == "prone") or ("fall unconscious" in low and k == "incapacitated"):
					d["c"] = "stunned" if v == "held" else v
					break
			if "dmg" in d or "c" in d:
				aoe.append(d)
	if not atks:
		# без атак (визгун и т. п.) — слабый удар
		atks = [{"n": "Удар", "hit": max(0, ab["СИЛ"]) + 2, "dmg": "1d4", "dt": "дробящий"}]
	r["atks"] = atks
	melee = [a for a in atks if not a.get("r")]
	main = melee[0] if melee else atks[0]
	r["atk"] = main["hit"]
	r["dmg"] = main["dmg"]
	if any(a.get("r") for a in atks):
		r["bow"] = True
	if multi_desc:
		r["multi"] = multi_count(multi_desc, [a["n"] for a in atks])
	if aoe:
		r["aoe"] = aoe
	if x.get("legendary_actions"):
		r["leg"] = 3
	for s in x.get("special_abilities", []) or []:
		n = s["name"]
		d = s.get("desc", "")
		if n.startswith("Magic Resistance"):
			r["mres"] = True
		elif n.startswith("Legendary Resistance"):
			m = re.search(r"\((\d)/Day\)", n)
			r["lres"] = int(m.group(1)) if m else 3
		elif n.startswith("Pack Tactics"):
			r["pack"] = True
		elif n.startswith("Regeneration"):
			m = re.search(r"regains (\d+) hit points", d)
			r["regen"] = int(m.group(1)) if m else 10
		elif n.startswith("Undead Fortitude"):
			r["fort"] = True
		elif n.startswith("Nimble Escape"):
			r["nimble"] = True
		elif n.startswith("Sunlight Sensitivity"):
			r["sun"] = True
		elif n in ["Pounce", "Charge", "Trampling Charge"]:
			r["charge"] = True
		elif n.startswith("Death Burst"):
			m = re.search(r"\((\d+d\d+)\) (\w+) damage", d)
			if m:
				r["burst"] = {"dmg": m.group(1), "dt": DT.get(m.group(2), "огонь")}
		elif n.startswith("Incorporeal"):
			r["ghost"] = True
		elif n.startswith("Rejuvenation"):
			r["rejuv"] = True
		elif n.startswith("Blood Frenzy"):
			r["frenzy"] = True
		elif n.startswith("Sneak Attack"):
			r["sneak"] = True
		elif n.startswith("Brute"):
			r["brute"] = True
		elif n.startswith("Reckless"):
			r["reckless"] = True
		elif "Spellcasting" in n:
			low = d.lower()
			m = re.search(r"spell save dc (\d+)", low)
			m2 = re.search(r"\+(\d+) to hit with spell attacks", low)
			sps = []
			for k, v in SPELL_MAP.items():
				if re.search(r"\b" + re.escape(k) + r"\b", low) and v not in sps:
					sps.append(v)
			if sps:
				c = r.get("caster", {"dc": 12, "hit": 4, "sp": [], "slots": 0})
				if m:
					c["dc"] = int(m.group(1))
				if m2:
					c["hit"] = int(m2.group(1))
				for v in sps:
					if v not in c["sp"]:
						c["sp"].append(v)
				lv = re.search(r"is an? (\d+)\w\w-level spellcaster", low)
				c["slots"] = max(c["slots"], min(4, (int(lv.group(1)) + 2) // 3) if lv else 2)
				r["caster"] = c
	return slug(en), r


def main():
	src = json.load(open(SRC, encoding="utf-8"))
	out = {}
	for x in src:
		k, r = convert(x)
		out[k] = r
	os.makedirs(os.path.dirname(OUT), exist_ok=True)
	json.dump(out, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
	print("monsters:", len(out), "→", OUT, os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
	main()
