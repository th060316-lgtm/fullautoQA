# data/social/relationship_thresholds.tres
# Data-driven thresholds for relationship decisions.
# Adjustable without code changes.

extends Resource
class_name RelationshipThresholds

## Affection value thresholds
const AFFECTION_HOSTILE_CERTAIN: int = -80
const AFFECTION_HOSTILE_LIKELY: int = -50
const AFFECTION_DANGER_ZONE_NEG: int = -10
const AFFECTION_DANGER_ZONE_POS: int = 10
const AFFECTION_FRIENDLY: int = 50
const AFFECTION_DEVOTED: int = 80

## Trust thresholds
const TRUST_LOW: int = 20
const TRUST_MEDIUM: int = 50
const TRUST_HIGH: int = 75

## Fear thresholds
const FEAR_SCARED: int = 30
const FEAR_TERRIFIED: int = 60

## Interaction thresholds
const INTERACTION_RECENT_DECAY: int = 100
const INTERACTION_RECENT_DECAY_RATE: float = 0.3

## Relationship graph thresholds
const RELATIONSHIP_POSITIVE_THRESHOLD: float = 20.0
const RELATIONSHIP_NEGATIVE_THRESHOLD: float = -20.0

## Time costs (in minutes)
const TIME_TALK_SHORT: int = 15
const TIME_TALK_LONG: int = 30
const TIME_RESCUE: int = 60
const TIME_DELIVERY: int = 45
const TIME_INVESTIGATION: int = 90
