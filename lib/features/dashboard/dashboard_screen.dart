import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:intl/intl.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Map<String, dynamic>> _sankeyLinksData = [];
  bool _isLoading = false;
  String? _errorMessage;
  String _selectedPeriod = "monthly";
  int _dateOffset = 0;
  double? _totalIncome;
  double? _totalExpenses;
  double? _savingsBuffer;

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  @override
  void initState() {
    super.initState();
    _fetchSankeyData();
  }

  Future<void> _fetchSankeyData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final HttpsCallable callable = _functions.httpsCallable('getSankeyData');
      final HttpsCallableResult result = await callable.call(<String, dynamic>{
        'period': _selectedPeriod,
        'dateOffset': _dateOffset,
      });

      if (result.data != null && result.data['links'] != null) {
        final List<dynamic> linksData = result.data['links'];
        setState(() {
          _sankeyLinksData = linksData.map((link) => {
            'from': link['from'] as String,
            'to': link['to'] as String,
            'value': link['value'] as num,
          }).toList();
          _totalIncome = (result.data['totalIncome'] as num?)?.toDouble();
          _totalExpenses = (result.data['totalExpenses'] as num?)?.toDouble();
          _savingsBuffer = (result.data['savingsBuffer'] as num?)?.toDouble();
        });
      } else {
        setState(() {
          _sankeyLinksData = [];
          _totalIncome = null;
          _totalExpenses = null;
          _savingsBuffer = null;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _errorMessage = e.message ?? "An unknown error occurred.";
        _sankeyLinksData = [];
        _totalIncome = null;
        _totalExpenses = null;
        _savingsBuffer = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = "An unexpected error occurred: $e";
        _sankeyLinksData = [];
        _totalIncome = null;
        _totalExpenses = null;
        _savingsBuffer = null;
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sankey Diagram'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('Monthly'),
                  selected: _selectedPeriod == 'monthly',
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedPeriod = 'monthly';
                        _dateOffset = 0; // Reset offset when changing period type
                      });
                      _fetchSankeyData();
                    }
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Yearly'),
                  selected: _selectedPeriod == 'yearly',
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedPeriod = 'yearly';
                        _dateOffset = 0; // Reset offset
                      });
                      _fetchSankeyData();
                    }
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('YTD'),
                  selected: _selectedPeriod == 'ytd',
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedPeriod = 'ytd';
                        _dateOffset = 0; // YTD is always current year, offset 0
                      });
                      _fetchSankeyData();
                    }
                  },
                ),
              ],
            ),
          ),
          // Optional: Add Previous/Next buttons here for monthly/yearly
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? Center(child: Text('Error: $_errorMessage'))
                    : _sankeyLinksData.isEmpty
                        ? const Center(child: Text('No data available for the selected period.'))
                        : Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: SfSankey(
                              title: SankeyTitle(text: 'Financial Flow Analysis'),
                              links: _sankeyLinksData.map((linkData) => SankeyLink(
                                source: linkData['from']!,
                                target: linkData['to']!,
                                value: (linkData['value'] as num).toDouble(),
                              )).toList(),
                              nodeStyle: SankeyNodeStyle(
                                color: Colors.teal.withOpacity(0.7),
                                borderColor: Colors.black54,
                                borderWidth: 0.5,
                                labelStyle: const TextStyle(fontSize: 11, color: Colors.black87, fontWeight: FontWeight.w500),
                              ),
                              linkStyle: SankeyLinkStyle(
                                colorMode: SankeyLinkColorMode.target, // Color links based on target node
                                color: Colors.blueGrey.withOpacity(0.4), // Default, might be overridden by colorMode
                                // activeColor: Colors.deepPurpleAccent, // Color on interaction
                              ),
                              dataLabelSettings: SankeyDataLabelSettings(
                                isVisible: true,
                                labelPosition: SankeyLabelPosition.center, // Adjust as needed
                                textStyle: const TextStyle(fontSize: 9, color: Colors.black),
                                builder: (BuildContext context, SankeyLinkDetails details, SankeyDataLabelRenderDetails renderDetails) {
                                  final value = renderDetails.value;
                                  final formattedValue = NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(value);
                                  return Text(formattedValue, style: const TextStyle(fontSize: 9, color: Colors.black));
                                }
                              ),
                              tooltipSettings: SankeyTooltipSettings(
                                enable: true,
                                textStyle: const TextStyle(fontSize: 10),
                              ),
                            ),
                          ),
          ),
          // Optional: Display summary figures
          if (_totalIncome != null && _totalExpenses != null && _savingsBuffer != null && !_isLoading && _errorMessage == null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text('Total Income: ${_totalIncome?.toStringAsFixed(2)}'),
                  Text('Total Expenses: ${_totalExpenses?.toStringAsFixed(2)}'),
                  Text('Savings/Buffer: ${_savingsBuffer?.toStringAsFixed(2)}'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}