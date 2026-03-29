<?php
require(__DIR__ . '/common.php');
$db = get_db_instance();

$accounts_per_instance = 250;
$max_instances = 8;
$instance_chars = 'abcdefgh';

$stmt = $db->query('SELECT instance, COUNT(*) as cnt FROM onions WHERE enabled IN (1, -2) GROUP BY instance;');
$loads = [];
while($row = $stmt->fetch(PDO::FETCH_ASSOC)){
	$loads[$row['instance']] = (int)$row['cnt'];
}

$current = SERVICE_INSTANCES;
$total_accounts = array_sum($loads);
$needed = max(1, (int)ceil($total_accounts / $accounts_per_instance));
$needed = min($needed, $max_instances);

if($needed <= count($current)){
	echo "OK: $total_accounts accounts across " . count($current) . " instance(s), no scaling needed\n";
	exit(0);
}

$new_instances = $current;
for($i = count($current); $i < $needed; $i++){
	$char = $instance_chars[$i];
	if(!in_array($char, $new_instances)){
		$new_instances[] = $char;
	}
}

$old_str = "const SERVICE_INSTANCES=['" . implode("','", $current) . "']";
$new_str = "const SERVICE_INSTANCES=['" . implode("','", $new_instances) . "']";

$common = file_get_contents('/var/www/common.php');
if(strpos($common, $old_str) === false){
	echo "ERROR: could not find SERVICE_INSTANCES in common.php\n";
	exit(1);
}

file_put_contents('/var/www/common.php', str_replace($old_str, $new_str, $common));
echo "SCALED: $total_accounts accounts, " . count($current) . " -> " . count($new_instances) . " instances ($new_str)\n";

echo "Running setup.php to create new instances...\n";
require(__DIR__ . '/setup.php');
